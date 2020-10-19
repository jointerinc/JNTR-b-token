// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.9;

import "./Ownable.sol";

interface IBEP20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract GatewayVault is Ownable {

    mapping(address => bool) public gateways; // different gateways will be used for different pairs (chains)
    event ChangeGateway(address gateway, bool active);


    /**
     * @dev Throws if called by any account other than the Gateway.
     */
    modifier onlyGateway() {
        require(gateways[msg.sender],"Not Gateway");
        _;
    }

    function changeGateway(address gateway, bool active) external onlyOwner returns(bool) {
        gateways[gateway] = active;
        emit ChangeGateway(gateway, active);
        return true;
    }

    function vaultTransfer(address token, address recipient, uint256 amount) external onlyGateway returns (bool) {
        return IBEP20(token).transfer(recipient, amount);
    }

    function vaultApprove(address token, address spender, uint256 amount) external onlyGateway returns (bool) {
        return IBEP20(token).approve(spender, amount);
    }
}