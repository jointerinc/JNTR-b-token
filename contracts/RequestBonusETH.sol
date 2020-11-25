// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.9;

import "./Ownable.sol";

contract RequestBonusETH is Ownable {
    uint256 public fee = 250 szabo; // 0.00025 ETH
    address public system;          // system address may change fee amount
    address payable public company; // company address receive fee
    mapping (address => uint256) public companyRate;       // % the our company received as fee (with 2 decimals i.e. 1250 = 12.5%)
    mapping (address => uint256[]) private allowedAmount;   // amount of ETH that have to be send to request bonus
    mapping (address => address payable) public bonusOwners;
    mapping (address => bool) public isActive;
    mapping(address => mapping(address => uint256)) public paidETH; // token => user => paid ETH amount
    event TokenRequest(address indexed token, address indexed user, uint256 amount);
    event CompanyRate(address indexed token, uint256 rate);

    modifier onlySystem() {
        require(msg.sender == system || isOwner(), "Caller is not the system");
        _;
    }

    constructor (address _system, address payable _company) public {
        require(_company != address(0) && _system != address(0));
        system = _system;
        company = _company;
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }

    // set our company rate in % that will be send to it as a fee
    function setCompanyRate(address token, uint256 _rate) external onlyOwner returns(bool) {
        require(_rate <= 10000);
        companyRate[token] = _rate;
        emit CompanyRate(token, _rate);
        return true;
    }

    function setSystem(address _system) external onlyOwner returns(bool) {
        require(_system != address(0));
        system = _system;
        return true;
    }

    function setFee(uint256 _fee) external onlySystem returns(bool) {
        fee = _fee;
        return true;
    }

    function setCompany(address payable _company) external onlyOwner returns(bool) {
        require(_company != address(0));
        company = _company;
        return true;
    }

    function getAllowedAmount(address token) external view returns(uint256[] memory) {
        return allowedAmount[token];
    }
    
    function tokenRequest(address token) public payable {
        require(isActive[token], "Not not active");
        require(fee < msg.value, "Not enough value");
        require(paidETH[token][msg.sender] == 0, "You already requested tokens");
        uint256 value = msg.value - fee;
        require(isAllowedAmount(token, value), "Wrong value");
        paidETH[token][msg.sender] = value;
        uint256 companyPart = value * companyRate[token] / 10000 + fee;
        safeTransferETH(company, companyPart);
        safeTransferETH(bonusOwners[token], msg.value - companyPart);
        emit TokenRequest(token, msg.sender, value);
    }

    function isAllowedAmount(address token, uint256 amount) internal view returns(bool) {
        uint256 len = allowedAmount[token].length;
        for (uint256 i = 0; i < len; i++) {
            if(allowedAmount[token][i] == amount) {
                return true;
            }
        }
        return false;
    }

    function registerBonus(
        address token,              // token contract address
        address payable bonusOwner, // owner of bonus program (who create bonus program)
        uint256 rate,               // % the our company received as fee (with 2 decimals i.e. 1250 = 12.5%)
        uint256[] memory amountETH  // amount of ETH that have to be send to request bonus
    ) external onlySystem returns(bool) {
        require(bonusOwners[token] == address(0) && bonusOwner != address(0));
        companyRate[token] = rate;
        bonusOwners[token] = bonusOwner;
        createOptions(token, amountETH);
        isActive[token] = true;
        return true;
    }

    // create set of options by customer (bonusOwner)
    function createOptions(
        address token,              // token contract address
        uint256[] memory amountETH // amount of ETH that have to be send to request bonus
    ) public returns(bool) {
        require(msg.sender == bonusOwners[token] || msg.sender == system, "Caller is not the bonusOwners or system");
        if(allowedAmount[token].length > 0) delete allowedAmount[token];    // delete old allowedAmount if exist
        allowedAmount[token] = amountETH;
        /*
        for (uint256 i = 0; i < amountETH.length; i++) {
            allowedAmount[token].push(amountETH[i]);
        }
        */
        return true;
    }

    function setActiveBonus(address token, bool active) external returns(bool) {
        require(msg.sender == bonusOwners[token], "Caller is not the bonusOwners");
        isActive[token] = active;
        return true;
    }

    // allow bonus owner change address
    function changeBonusOwner(address token, address payable newBonusOwner) external returns(bool) {
        require(newBonusOwner != address(0));
        require(msg.sender == bonusOwners[token], "Caller is not the bonusOwners");
        bonusOwners[token] = newBonusOwner;
        return true;
    }
}