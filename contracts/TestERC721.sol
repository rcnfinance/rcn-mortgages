pragma solidity ^0.4.19;

import "./interfaces/ERC721.sol";
import "./utils/Ownable.sol";

contract TERC721 is Ownable {
    struct Received {
        address from;
        uint256 tokenId;
        bytes data;
    }

    Received[] public receivedHistory;

    function sendToken(ERC721 token, address to, uint256 id) public onlyOwner returns (bool) {
        return token.transfer(to ,id);
    }

    function onERC721Received(address _from, uint256 _tokenId, bytes data) external returns (bytes4) {
        receivedHistory.push(Received(_from, _tokenId, data));
        return bytes4(keccak256("onERC721Received(address,uint256,bytes)"));
    }
}