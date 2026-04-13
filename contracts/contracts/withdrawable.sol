// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Import the Ownable contract from OpenZeppelin
import "@openzeppelin/contracts/access/Ownable.sol";

contract Withdrawable is Ownable {
    uint256 public variable = 0;
    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}

    // Function to withdraw all Ether from this contract
    function withdraw(address to) external onlyOwner {
        // Get the balance of the contract
        uint256 balance = address(this).balance;

        // Transfer the balance to the owner
        payable(to).transfer(balance);
    }

    function changeValue() external  {
        variable += 1;
    }
}