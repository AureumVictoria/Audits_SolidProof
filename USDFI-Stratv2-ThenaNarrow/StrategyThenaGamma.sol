// SPDX-License-Identifier: Business Source License 1.1

pragma solidity ^0.8.0;

import "./SafeERC20.sol";
import "./ISolidlyPair.sol";
import "./IRewardPool.sol";
import "./IERC20Extended.sol";
import "./AlgebraUtils.sol";
import "./OwnableUpgradeable.sol";
import "./PausableUpgradeable.sol";

interface IGammaUniProxy {
    function getDepositAmount(
        address pos,
        address token,
        uint256 _deposit
    ) external view returns (uint256 amountStart, uint256 amountEnd);

    function deposit(
        uint256 deposit0,
        uint256 deposit1,
        address to,
        address pos,
        uint256[4] memory minIn
    ) external returns (uint256 shares);
}

interface IAlgebraPool {
    function pool() external view returns (address);

    function globalState() external view returns (uint256);
}

interface IAlgebraQuoter {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint16[] memory fees);
}

interface IHypervisor {
    function whitelistedAddress() external view returns (address uniProxy);
}

contract UsdfiMoneyLegoV3ThenaGammaStrategy is
    OwnableUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // Tokens used
    address public constant native = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant output = 0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public rewardPool;
    IGammaUniProxy public uniProxy;
    IAlgebraQuoter public constant quoter = IAlgebraQuoter(0xeA68020D6A9532EeC42D4dB0f92B83580c39b2cA);

    // common addresses for the strategy
    address public vault;
    address public unirouter;
    address public rewarder;

    bool public isFastQuote;
    bool public harvestOnDeposit;
    uint256 public lastHarvest;

    bytes public outputToNativePath;
    bytes public nativeToLp0Path;
    bytes public nativeToLp1Path;

    uint256 constant DIVISOR = 1 ether;
    uint256 public constant WITHDRAWAL_FEE_CAP = 50;
    uint256 public constant WITHDRAWAL_MAX = 10000;
    uint256 public withdrawalFee;
    uint256 public rewardRate;
    uint256 public maxGasPrice;

    event StratHarvest(
        address indexed harvester,
        uint256 wantHarvested,
        uint256 tvl
    );
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event SetWithdrawalFee(uint256 withdrawalFee);
    event SetVault(address vault);
    event SetUnirouter(address unirouter);
    event SetRewarder(address rewarder);
    event SendRewards(uint256 nativeRewardBal);
    event SetRewardRate(uint256 rewardRate);
    event NewMaxGasPrice(uint oldPrice, uint newPrice);

    function initialize(
        address _want,
        address _rewardPool,
        address _vault,
        address _unirouter,
        bytes calldata _outputToNativePath,
        bytes calldata _nativeToLp0Path,
        bytes calldata _nativeToLp1Path
    ) public initializer {
        __Ownable_init();
        __Pausable_init();
        want = _want;
        rewardPool = _rewardPool;
        vault = _vault;
        unirouter = _unirouter;

        lpToken0 = ISolidlyPair(want).token0();
        lpToken1 = ISolidlyPair(want).token1();

        setOutputToNative(_outputToNativePath);
        setNativeToLp0(_nativeToLp0Path);
        setNativeToLp1(_nativeToLp1Path);

        harvestOnDeposit = true;
        withdrawalFee = 10;
        rewardRate = 90;
        maxGasPrice = 5000000000;

        setGammaProxy();
        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IRewardPool(rewardPool).deposit(wantBal);
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IRewardPool(rewardPool).withdraw(_amount - wantBal);
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = (wantBal * withdrawalFee) /
                WITHDRAWAL_MAX;
            wantBal = wantBal - withdrawalFeeAmount;
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external virtual {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest();
        }
    }

    function harvest() external virtual {
        require(tx.gasprice <= maxGasPrice, "gas is too high!");
        _harvest();
    }

    // compounds earnings and charges performance fee
    function _harvest() internal whenNotPaused {
        IRewardPool(rewardPool).getReward();
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            swapRewardsToNative();
            chargeFees();
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    function swapRewardsToNative() internal {
        uint256 bal = IERC20(output).balanceOf(address(this));
        AlgebraUtils.swap(unirouter, outputToNativePath, bal);
    }

    // performance fees
    function chargeFees() internal {
        uint256 nativeRewardBal = (IERC20(native).balanceOf(address(this)) *
            rewardRate) / 100;

        IERC20(native).safeTransfer(rewarder, nativeRewardBal);

        emit SendRewards(nativeRewardBal);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        (uint256 toLp0, uint256 toLp1) = quoteAddLiquidity();

        if (nativeToLp0Path.length > 0) {
            AlgebraUtils.swap(unirouter, nativeToLp0Path, toLp0);
        }
        if (nativeToLp1Path.length > 0) {
            AlgebraUtils.swap(unirouter, nativeToLp1Path, toLp1);
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));

        (uint256 amount1Start, uint256 amount1End) = uniProxy.getDepositAmount(want, lpToken0, lp0Bal);
        if (lp1Bal > amount1End) {
            lp1Bal = amount1End;
        } else if (lp1Bal < amount1Start) {
            (, lp0Bal) = uniProxy.getDepositAmount(want, lpToken1, lp1Bal);
        }

        uint256[4] memory minIn;
        uniProxy.deposit(lp0Bal, lp1Bal, address(this), want, minIn);
    }

    function quoteAddLiquidity()
        internal
        returns (uint256 toLp0, uint256 toLp1)
    {
        uint256 nativeBal = IERC20(native).balanceOf(address(this));
        uint256 ratio;

        if (isFastQuote) {
            uint256 lp0Decimals = 10**IERC20Extended(lpToken0).decimals();
            uint256 lp1Decimals = 10**IERC20Extended(lpToken1).decimals();
            uint256 decimalsDiff = (1e18 * lp0Decimals) / lp1Decimals;
            uint256 decimalsDenominator = decimalsDiff > 1e12 ? 1e6 : 1;
            uint256 sqrtPriceX96 = IAlgebraPool(IAlgebraPool(want).pool())
                .globalState();
            uint256 price = ((sqrtPriceX96**2 *
                (decimalsDiff / decimalsDenominator)) / (2**192)) *
                decimalsDenominator;
            (uint256 amountStart, uint256 amountEnd) = uniProxy
                .getDepositAmount(want, lpToken0, lp0Decimals);
            uint256 amountB = (((amountStart + amountEnd) / 2) * 1e18) /
                lp1Decimals;
            ratio = (amountB * 1e18) / price;
        } else {
            uint256 lp0Amt = nativeBal / 2;
            uint256 lp1Amt = nativeBal - lp0Amt;
            uint256 out0 = lp0Amt;
            uint256 out1 = lp1Amt;
            if (nativeToLp0Path.length > 0) {
                (out0, ) = quoter.quoteExactInput(nativeToLp0Path, lp0Amt);
            }
            if (nativeToLp1Path.length > 0) {
                (out1, ) = quoter.quoteExactInput(nativeToLp1Path, lp1Amt);
            }
            (uint256 amountStart, uint256 amountEnd) = uniProxy
                .getDepositAmount(want, lpToken0, out0);
            uint256 amountB = (amountStart + amountEnd) / 2;
            ratio = (amountB * 1e18) / out1;
        }

        toLp0 = (nativeBal * 1e18) / (ratio + 1e18);
        toLp1 = nativeBal - toLp0;
    }

    function setFastQuote(bool _isFastQuote) external onlyOwner {
        isFastQuote = _isFastQuote;
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant() + balanceOfPool();
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        return IRewardPool(rewardPool).balanceOf(address(this));
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        return IRewardPool(rewardPool).earned(address(this));
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyOwner {
        harvestOnDeposit = _harvestOnDeposit;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        if (balanceOfPool() > 0) {
            if (IRewardPool(rewardPool).emergency())
                IRewardPool(rewardPool).emergencyWithdraw();
            else IRewardPool(rewardPool).withdraw(balanceOfPool());
        }

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyOwner {
        pause();
        if (IRewardPool(rewardPool).emergency())
            IRewardPool(rewardPool).emergencyWithdraw();
        else IRewardPool(rewardPool).withdraw(balanceOfPool());
    }

    function pause() public onlyOwner {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyOwner {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).approve(rewardPool, type(uint256).max);
        IERC20(output).approve(unirouter, type(uint256).max);
        IERC20(native).approve(unirouter, type(uint256).max);

        IERC20(lpToken0).approve(want, 0);
        IERC20(lpToken0).approve(want, type(uint256).max);
        IERC20(lpToken1).approve(want, 0);
        IERC20(lpToken1).approve(want, type(uint256).max);
    }

    function _removeAllowances() internal {
        IERC20(want).approve(rewardPool, 0);
        IERC20(output).approve(unirouter, 0);
        IERC20(native).approve(unirouter, 0);

        IERC20(lpToken0).approve(want, 0);
        IERC20(lpToken1).approve(want, 0);
    }

    function setOutputToNative(bytes calldata _outputToNativePath)
        public
        onlyOwner
    {
        if (_outputToNativePath.length > 0) {
            address[] memory route = AlgebraUtils.pathToRoute(
                _outputToNativePath
            );
            require(route[0] == output, "!output");
        }
        outputToNativePath = _outputToNativePath;
    }

    function setNativeToLp0(bytes calldata _nativeToLp0Path) public onlyOwner {
        if (_nativeToLp0Path.length > 0) {
            address[] memory route = AlgebraUtils.pathToRoute(_nativeToLp0Path);
            require(route[0] == native, "!native");
            require(route[route.length - 1] == lpToken0, "!lp0");
        }
        nativeToLp0Path = _nativeToLp0Path;
    }

    function setNativeToLp1(bytes calldata _nativeToLp1Path) public onlyOwner {
        if (_nativeToLp1Path.length > 0) {
            address[] memory route = AlgebraUtils.pathToRoute(_nativeToLp1Path);
            require(route[0] == native, "!native");
            require(route[route.length - 1] == lpToken1, "!lp1");
        }
        nativeToLp1Path = _nativeToLp1Path;
    }

    function setGammaProxy() public {
        uniProxy = IGammaUniProxy(IHypervisor(want).whitelistedAddress());
    }

    function outputToNative() external view returns (address[] memory) {
        return AlgebraUtils.pathToRoute(outputToNativePath);
    }

    function nativeToLp0() external view returns (address[] memory) {
        return AlgebraUtils.pathToRoute(nativeToLp0Path);
    }

    function nativeToLp1() external view returns (address[] memory) {
        return AlgebraUtils.pathToRoute(nativeToLp1Path);
    }

    // adjust withdrawal fee
    function setWithdrawalFee(uint256 _fee) external onlyOwner {
        require(_fee <= WITHDRAWAL_FEE_CAP, "!cap");
        withdrawalFee = _fee;
        emit SetWithdrawalFee(_fee);
    }

    // set new unirouter
    function setUnirouter(address _unirouter) external onlyOwner {
        unirouter = _unirouter;
        emit SetUnirouter(_unirouter);
    }

    // set new rewarder to manage gas token rewards
    function setRewarder(address _rewarder) external onlyOwner {
        rewarder = _rewarder;
        emit SetRewarder(_rewarder);
    }

    // set new reward rate to manage gas token rewards
    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        require(0 < _rewardRate, "more 0");
        require(100 > _rewardRate, "lower 100");
        rewardRate = _rewardRate;
        emit SetRewardRate(_rewardRate);
    }

    function setMaxGasPrice(uint _maxGasPrice) external onlyOwner {
        emit NewMaxGasPrice(maxGasPrice, _maxGasPrice);
        maxGasPrice = _maxGasPrice;
    }

    function depositFee() public view virtual returns (uint256) {
        return 0;
    }

    function withdrawFee() public view virtual returns (uint256) {
        return paused() ? 0 : withdrawalFee;
    }
}
