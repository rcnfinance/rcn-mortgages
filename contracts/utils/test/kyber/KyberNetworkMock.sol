pragma solidity ^0.4.19;

import "./../../../utils/Ownable.sol";
import "./../../../interfaces/Token.sol";

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

contract KyberMock is KyberNetwork, Ownable {
    Token public MANA;
    Token public RCN;

    uint256 public rateMR;
    uint256 public rateRM;

    function KyberMock(Token _MANA, Token _RCN) public {
        MANA = _MANA;
        RCN = _RCN;
    }

    function withdraw(Token token, address to, uint256 amount) public onlyOwner returns (bool) {
        return token.transfer(to, amount);
    }

    function setRateMR(uint256 _rateMR) public onlyOwner returns (bool) {
        rateMR = _rateMR;
        return true;
    }

    function setRateRM(uint256 _rateRM) public onlyOwner returns (bool) {
        rateRM = _rateRM;
        return true;
    }

    function trade(
        Token src,
        uint srcAmount,
        Token dest,
        address destAddress,
        uint maxDestAmount,
        uint minConversionRate,
        address
    ) public payable returns(uint) {
        uint256 rate;
        (rate, ) = getExpectedRate(src, dest, 0);
        require(rate > minConversionRate);
        require(src.transferFrom(msg.sender, this, srcAmount));
        uint256 destAmount = convertRate(srcAmount, rate);
        require(destAmount < maxDestAmount);
        require(dest.transfer(destAddress, destAmount));
        return destAmount;
    }

    function convertRate(uint256 amount, uint256 rate) public pure returns (uint256) {
        return (amount * rate) / 10**18;
    }

    function getExpectedRate(Token src, Token dest, uint256) public view returns (uint256, uint256) {
        if (src == MANA && dest == RCN) {
            return (rateMR, rateMR);
        } else if (src == RCN && dest == MANA) {
            return (rateRM, rateRM);
        }

        revert();
    }
}
