// SPDX-License-Identifier: MIT

import "./IERC20.sol";
import "./ReentrancyGuard.sol";

pragma solidity =0.8.19;


contract StableMigration is ReentrancyGuard {

    event Migration(address indexed addr, uint256 amount);

    address public constant HOLE = 0x000000000000000000000000000000000000dEaD;
    address public constant owner = 0xf594a4124bBD13eAcdcDf6f2Abaf5482B63ab032;
    IERC20  public constant oldToken = IERC20(0xa3870fbBeb730BA99e4107051612af3465CA9F5e);
    IERC20 public constant newToken = IERC20(0x8bF75bc68FD337dfd8186d731Df8b3C2CB14B9E6);

    function migrate(uint256 _amount) external nonReentrant {
        require(oldToken.transferFrom(msg.sender, HOLE, _amount), "Transfer of old tokens failed");
        require(newToken.transfer(msg.sender, _amount), "Transfer of new tokens failed");
        emit Migration(msg.sender, _amount);
    }

    function withdrawNewTokens() public nonReentrant {
        require(msg.sender == owner, "Only DAO");
        uint256 balance = newToken.balanceOf(address(this));
        require(newToken.transfer(owner, balance), "Transfer failed");
    }
}