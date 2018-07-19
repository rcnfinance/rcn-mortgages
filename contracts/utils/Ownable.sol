pragma solidity ^0.4.24;

contract Ownable {
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Sender not owner");
        _;
    }

    function Ownable() public {
        owner = msg.sender; 
    }

    /**
        @dev Transfers the ownership of the contract.

        @param _to Address of the new owner
    */
    function transferTo(address _to) public onlyOwner returns (bool) {
        require(_to != address(0));
        owner = _to;
        return true;
    } 
} 