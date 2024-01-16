// SPDX-License-Identifier: Business Source License 1.1

pragma solidity ^0.8.0;

import "./SafeERC20.sol";
import "./ISolidlyPair.sol";
import "./ISolidlyRouter.sol";
import "./IRewardPool.sol";
import "./IERC20Extended.sol";
import "./AlgebraUtils.sol";
import "./OwnableUpgradeable.sol";
import "./PausableUpgradeable.sol";

contract SolidlyCommonStrategy is OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // Tokens used
    address public native;
    address public output;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public vault;
    address public unirouter;
    address public rewardPool;

    bool public stable;
    bool public harvestOnDeposit;
    uint256 public lastHarvest;

    ISolidlyRouter.Routes[] public outputToNativeRoute;
    ISolidlyRouter.Routes[] public outputToLp0Route;
    ISolidlyRouter.Routes[] public outputToLp1Route;
    address[] public rewards;

    uint256 public constant WITHDRAWAL_FEE_CAP = 50;
    uint256 public constant WITHDRAWAL_MAX = 10000;
    uint256 public maxGasPrice;
    uint256 public withdrawalFee;

    uint256 public rewardRate;
    address public rewarder;

    event StratHarvest(
        address indexed harvester,
        uint256 wantHarvested,
        uint256 tvl
    );
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event SetWithdrawalFee(uint256 withdrawalFee);
    event SendRewards(uint256 nativeRewardBal);
    event SetUnirouter(address unirouter);
    event SetRewardPool(address rewardPool);
    event SetRewarder(address rewarder);
    event SetRewardRate(uint256 rewardRate);
    event NewMaxGasPrice(uint256 oldPrice, uint256 newPrice);

    function initialize(
        address _want,
        address _rewardPool,
        address _vault,
        address _unirouter,
        ISolidlyRouter.Routes[] calldata _outputToNativeRoute,
        ISolidlyRouter.Routes[] calldata _outputToLp0Route,
        ISolidlyRouter.Routes[] calldata _outputToLp1Route
    ) public initializer {
        __Ownable_init();
        __Pausable_init();
        want = _want;
        rewardPool = _rewardPool;
        vault = _vault;
        unirouter = _unirouter;

        harvestOnDeposit = true;
        withdrawalFee = 10;
        rewardRate = 90;
        maxGasPrice = 5000000000;

        stable = ISolidlyPair(want).stable();

        for (uint256 i; i < _outputToNativeRoute.length; ++i) {
            outputToNativeRoute.push(_outputToNativeRoute[i]);
        }

        for (uint256 i; i < _outputToLp0Route.length; ++i) {
            outputToLp0Route.push(_outputToLp0Route[i]);
        }

        for (uint256 i; i < _outputToLp1Route.length; ++i) {
            outputToLp1Route.push(_outputToLp1Route[i]);
        }

        output = outputToNativeRoute[0].from;
        native = outputToNativeRoute[outputToNativeRoute.length - 1].to;
        lpToken0 = outputToLp0Route[outputToLp0Route.length - 1].to;
        lpToken1 = outputToLp1Route[outputToLp1Route.length - 1].to;

        rewards.push(output);
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

    function beforeDeposit() external {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest();
        }
    }

    function harvest() external {
        _harvest();
    }

    // compounds earnings and charges performance fee
    function _harvest() internal whenNotPaused {
        require(tx.gasprice <= maxGasPrice, "gas is too high!");
        IRewardPool(rewardPool).getReward();
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            chargeFees();
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees
    function chargeFees() internal {
        uint256 toNative = (IERC20(output).balanceOf(address(this)) *
            rewardRate) / 100;

        ISolidlyRouter(unirouter).swapExactTokensForTokens(
            toNative,
            0,
            outputToNativeRoute,
            address(this),
            block.timestamp
        );

        uint256 nativeRewardBal = IERC20(native).balanceOf(address(this));

        IERC20(native).safeTransfer(
            rewarder,
            IERC20(native).balanceOf(address(this))
        );

        emit SendRewards(nativeRewardBal);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        uint256 lp0Amt = outputBal / 2;
        uint256 lp1Amt = outputBal - lp0Amt;

        if (stable) {
            uint256 lp0Decimals = 10**IERC20Extended(lpToken0).decimals();
            uint256 lp1Decimals = 10**IERC20Extended(lpToken1).decimals();
            uint256 out0 = (ISolidlyRouter(unirouter).getAmountsOut(
                lp0Amt,
                outputToLp0Route
            )[outputToLp0Route.length] * 1e18) / lp0Decimals;
            uint256 out1 = (ISolidlyRouter(unirouter).getAmountsOut(
                lp1Amt,
                outputToLp1Route
            )[outputToLp1Route.length] * 1e18) / lp1Decimals;
            (uint256 amountA, uint256 amountB, ) = ISolidlyRouter(unirouter)
                .quoteAddLiquidity(lpToken0, lpToken1, stable, out0, out1);
            amountA = (amountA * 1e18) / lp0Decimals;
            amountB = (amountB * 1e18) / lp1Decimals;
            uint256 ratio = (((out0 * 1e18) / out1) * amountB) / amountA;
            lp0Amt = (outputBal * 1e18) / (ratio + 1e18);
            lp1Amt = outputBal - lp0Amt;
        }

        if (lpToken0 != output) {
            ISolidlyRouter(unirouter).swapExactTokensForTokens(
                lp0Amt,
                0,
                outputToLp0Route,
                address(this),
                block.timestamp
            );
        }

        if (lpToken1 != output) {
            ISolidlyRouter(unirouter).swapExactTokensForTokens(
                lp1Amt,
                0,
                outputToLp1Route,
                address(this),
                block.timestamp
            );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        ISolidlyRouter(unirouter).addLiquidity(
            lpToken0,
            lpToken1,
            stable,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            block.timestamp
        );
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

        if (IRewardPool(rewardPool).emergency())
            IRewardPool(rewardPool).emergencyWithdraw();
        else IRewardPool(rewardPool).withdraw(balanceOfPool());

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
        IERC20(want).safeApprove(rewardPool, 0);
        IERC20(want).safeApprove(rewardPool, type(uint256).max);

        IERC20(output).safeApprove(unirouter, 0);
        IERC20(output).safeApprove(unirouter, type(uint256).max);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, type(uint256).max);

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, type(uint256).max);
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(rewardPool, 0);
        IERC20(output).safeApprove(unirouter, 0);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function _solidlyToRoute(ISolidlyRouter.Routes[] memory _route)
        internal
        pure
        returns (address[] memory)
    {
        address[] memory route = new address[](_route.length + 1);
        route[0] = _route[0].from;
        for (uint256 i; i < _route.length; ++i) {
            route[i + 1] = _route[i].to;
        }
        return route;
    }

    function setOutputToNativeRoute(
        ISolidlyRouter.Routes[] calldata _outputToNativeRoute
    ) external onlyOwner {
        delete outputToNativeRoute;
        for (uint256 i = 0; i < _outputToNativeRoute.length; ++i) {
            outputToNativeRoute.push(_outputToNativeRoute[i]);
        }
        output = outputToNativeRoute[0].from;
        native = outputToNativeRoute[outputToNativeRoute.length - 1].to;
    }

    function setOutputToLp0Route(
        ISolidlyRouter.Routes[] calldata _outputToLp0Route
    ) external onlyOwner {
        delete outputToLp0Route;
        for (uint256 i = 0; i < _outputToLp0Route.length; ++i) {
            outputToLp0Route.push(_outputToLp0Route[i]);
        }
        lpToken0 = outputToLp0Route[outputToLp0Route.length - 1].to;
    }

    function setOutputToLp1Route(
        ISolidlyRouter.Routes[] calldata _outputToLp1Route
    ) external onlyOwner {
        delete outputToLp1Route;
        for (uint256 i = 0; i < _outputToLp1Route.length; ++i) {
            outputToLp1Route.push(_outputToLp1Route[i]);
        }
        lpToken1 = outputToLp1Route[outputToLp1Route.length - 1].to;
    }

    function outputToNative() external view returns (address[] memory) {
        ISolidlyRouter.Routes[] memory _route = outputToNativeRoute;
        return _solidlyToRoute(_route);
    }

    function outputToLp0() external view returns (address[] memory) {
        ISolidlyRouter.Routes[] memory _route = outputToLp0Route;
        return _solidlyToRoute(_route);
    }

    function outputToLp1() external view returns (address[] memory) {
        ISolidlyRouter.Routes[] memory _route = outputToLp1Route;
        return _solidlyToRoute(_route);
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

    // set new reward pool
    function setRewardPool(address _rewardPool) external onlyOwner {
        rewardPool = _rewardPool;
        emit SetRewardPool(_rewardPool);
    }

    // set new rewarder to manage gas token rewards
    function setRewarder(address _rewarder) external onlyOwner {
        rewarder = _rewarder;
        emit SetRewarder(_rewarder);
    }

    // give Allowances
    function giveAllowances() external onlyOwner {
        _giveAllowances();
    }

    // set new reward rate to manage gas token rewards
    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        require(0 < _rewardRate, "more 0");
        require(100 > _rewardRate, "lower 100");
        rewardRate = _rewardRate;
        emit SetRewardRate(_rewardRate);
    }

    // set new gasPrice
    function setMaxGasPrice(uint256 _maxGasPrice) external onlyOwner {
        emit NewMaxGasPrice(maxGasPrice, _maxGasPrice);
        maxGasPrice = _maxGasPrice;
    }
}
