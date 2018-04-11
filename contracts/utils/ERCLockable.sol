pragma solidity ^0.4.19;

import "./Ownable.sol";
import "./../interfaces/Token.sol";
import "./RpSafeMath.sol";

contract ERCLockable is RpSafeMath, Ownable {
    enum TokenType { None, ERC20, ERC721 }
    mapping(address => mapping(uint256 => bool)) public lockedERC721;
    mapping(address => uint256) public lockedERC20;
    mapping(address => TokenType) internal tokenType;

    function setTokenType(address token, TokenType _type) internal {
        tokenType[token] = _type;
    }

    /**
        @dev Locked tokens cannot be withdrawn using the withdrawTokens function.
    */
    function lockERC20(address token, uint256 amount) internal {
        lockedERC20[token] = safeAdd(lockedERC20[token], amount);
    }

    /**
        @dev Unlocks previusly locked tokens.
    */
    function unlockERC20(address token, uint256 amount) internal {
        lockedERC20[token] = safeSubtract(lockedERC20[token], amount);
    }
    
    function lockERC721(address token, uint256 id) internal {
        lockedERC721[token][id] = true;
    }

    function unlockERC721(address token, uint256 id) internal {
        lockedERC721[token][id] = false;
    }

    /**
        @dev Withdraws tokens from the contract.

        @param token Token to withdraw
        @param to Destination of the tokens
        @param amountOrId Amount/ID to withdraw 
    */
    function withdrawTokens(Token token, address to, uint256 amountOrId) public onlyOwner returns (bool) {
        require(to != address(0));

        TokenType _type = tokenType[token];

        if (_type != TokenType.ERC721) {
            // If type is ERC20 or Unknown check balances
            require(safeSubtract(token.balanceOf(this), lockedERC20[token]) >= amountOrId);
        } else if (_type != TokenType.ERC20) {
            // If type is ERC721 or Unknown check locked ids
            require(!lockedERC721[token][amountOrId]);
        }

        return token.transfer(to, amountOrId);
    }
}