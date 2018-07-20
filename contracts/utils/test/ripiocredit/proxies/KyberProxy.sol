pragma solidity ^0.4.24;

import "./../../../../interfaces/Token.sol";
import "./../../../../interfaces/TokenConverter.sol";
import "./../../../Ownable.sol";

contract KyberNetwork {
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

contract KyberProxy is TokenConverter {
    uint256 private constant MAX_UINT = uint256(0) - 1;

    KyberNetwork kyber;

    constructor (KyberNetwork _kyber) public {
        kyber = _kyber;
    }

    function getReturn(Token from, Token to, uint256 sell) external view returns (uint256 amount){
        (amount,) = kyber.getExpectedRate(from, to, sell);
    }

    function convert(Token _from, Token _to, uint256 sell, uint256 minReturn) external payable returns (uint256 amount){
        require(_from.transferFrom(msg.sender, this, sell));
        require(_from.approve(kyber, sell));
        amount = kyber.trade(_from, sell, _to, this, MAX_UINT, 1, 0x0);
        require(_from.approve(kyber, 0));
        require(amount >= minReturn, "Min return not reached");
        require(_to.transfer(msg.sender, amount));
    }
}
