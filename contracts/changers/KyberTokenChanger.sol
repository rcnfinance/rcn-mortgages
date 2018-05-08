pragma solidity ^0.4.22;

import "./../interfaces/TokenChanger.sol";
import "./../interfaces/Token.sol";

contract Kyber {
    function trade(
        Token src,
        uint srcAmount,
        Token dest,
        address destAddress,
        uint maxDestAmount,
        uint minConversionRate,
        address walletId
    ) public payable returns(uint);

    function getExpectedRate(Token src, Token dest, uint srcQty)
        public view
        returns (uint expectedRate, uint slippageRate);
}

contract KyberTokenExchanger is TokenChanger {
    Kyber public kyber;

    constructor(Kyber _kyber) public {
        kyber = _kyber;
    }

    function change(Token _fromToken, Token _toToken, uint256 _amount, uint256 _minReturn) public returns (uint256 amount) {
        require(_fromToken.transferFrom(msg.sender, this, _amount));
        _fromToken.approve(kyber, _amount);
        amount = kyber.trade(_fromToken, _amount, _toToken, msg.sender, uint256(0) - 1, 0, this);
        require(amount >= _minReturn);
    }

    function getReturn(Token _fromToken, Token _toToken, uint256 _amount) public view returns (uint256 amount) {
        (amount, ) = kyber.getExpectedRate(_fromToken, _toToken, _amount);
    }
}