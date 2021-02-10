/**
 *Submitted for verification at BscScan.com on 2020-12-14
*/

// SPDX-License-Identifier: No License (None)
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

interface IBEP20 {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IPrice {
    function getCurrencyPrice(address _which) external view returns(uint256);   // 1 - BNB, 2 - ETH, 3 - BTC
}

abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev The Ownable constructor sets the original `owner` of the contract to the sender
     * account.
     */
    constructor () {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    /**
     * @return the address of the owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(isOwner(),"Not Owner");
        _;
    }

    /**
     * @return true if `msg.sender` is the owner of the contract.
     */
    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    /**
     * @dev Allows the current owner to relinquish control of the contract.
     * @notice Renouncing to ownership will leave the contract without an owner.
     * It will not be possible to call the functions with the `onlyOwner`
     * modifier anymore.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Allows the current owner to transfer control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0),"Zero address not allowed");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}


contract TokenVault {
    
    address public owner ;
    
    address public token ;
    
    
    constructor(address _owner,address _token) {
        owner = _owner;
        token = _token;
    }
    
    function transferToken(address _whom,uint256 _amount) external returns (bool){
        require(msg.sender == owner,"caller should be owner");
        safeTransfer(_whom,_amount);
        return true;
    }
    
    
    function safeTransfer(address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }
    
}



abstract contract Staking is Ownable {
    
    uint256 public fee = 0.3 ether; // 0.3 BNB Deploy Fee (200,000 Gas on ETH)
    
    uint256 constant RATE_NOMINATOR = 10000;    // rate nominator
    uint256 constant SECONDS = 31536000;    // number of seconde in a year (365 days)


    event NewOptionAdded(address indexed vault,  
        uint256[] amountETH,      
        uint256[] tokenMultiplier,    
        uint128[] period,    
        uint128[] rate );
    event Stake(address indexed vault, address indexed user, uint256 optionId, uint256 amount, uint256 startDate, uint128 period, uint128 rate);
    event Unstake(address indexed vault, address indexed user, uint256 amount);
    event WithdrawStaking(address indexed vault, address indexed user, uint256 amount);

    struct Option {
        uint256 amountETH;      // amount of ETH that have to be send to request bonus
        uint256 tokenMultiplier;    // multiply received USD amount by this value and send tokens with the same face value (with 2 decimals)
        uint128 period; // staking period in seconds
        uint128 rate;   // rate with 2 decimals (i.e. 4570 = 45.7%)
    }

    struct Order {
        uint256 amount; // amount what user get 
        uint256 reward; // reward what they get on stake
        uint256 startDate; // start date for stake
        uint128 period; // staking period in seconds
        uint128 rate;   // rate with 2 decimals (i.e. 4570 = 45.7%)
    }

    //IBEP20 public token;
    
    mapping (address => address payable) public vaultOwner;
    
    mapping (address => bool) public allowUnstake;
    
    mapping (address => Option[]) options;   // vault => Options. Options should be in order from lower `fromValue` to higher `fromValue`
    
    mapping (address => mapping (address => Order)) stakingOrders;  // vault => user => Order

    mapping (address => uint256) public tokenFaceValue; // price of token in USD with 9 decimals (vault address => token price).


    // Safe Math subtract function
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
  
    function safeTransfer(address token,address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }
  
    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }

    function getRewardsPool(address vault) public view returns(uint256 rewardsPool) {
        return IBEP20(TokenVault(vault).token()).balanceOf(vault);
    }

    function getNumberOptions(address vault) external view returns(uint256 number) {
        return options[vault].length;
    }

    function getOptions(address vault) external view returns(Option[] memory) {
        return options[vault];
    }

    function getOption(address vault, uint256 id) external view returns(Option memory option) {
        return options[vault][id];
    }

    function setAllowUnstake(address vault, bool _allowUnstake) external returns(bool) {
        require(msg.sender == vaultOwner[vault], "Caller is not the bonusOwners");
        allowUnstake[vault] = _allowUnstake;
        return true;
    }

    // allow bonus owner change address
    function changeVaultOwner(address vault, address payable newBonusOwner) external returns(bool) {
        require(newBonusOwner != address(0));
        require(msg.sender == vaultOwner[vault], "Caller is not the vault owner");
        vaultOwner[vault] = newBonusOwner;
        return true;
    }

    // create set of options by customer (bonusOwner)
    function addNewOptions(
        address vault,      // token contract address
        uint256[] memory amountETH,      // amount of ETH that have to be send to request bonus
        uint256[] memory tokenMultiplier,    // multiply received USD amount by this value and send tokens with the same face value (with 2 decimals)
        uint128[] memory period,    // staking period in seconds
        uint128[] memory rate       // percent per year with 2 decimals
    ) public payable returns(bool) {
        
        require(msg.value >= fee, "Not enough Deploy fee");
        require(msg.sender == vaultOwner[vault], "Caller is not the bonusOwners");
        _createOptions(vault,amountETH,tokenMultiplier,period,rate);
        emit NewOptionAdded(vault,amountETH,tokenMultiplier,period,rate); 
        return true;
    }
    
     function _createOptions(
        address vault,      // token contract address
        uint256[] memory amountETH,      // amount of ETH that have to be send to request bonus
        uint256[] memory tokenMultiplier,    // multiply received USD amount by this value and send tokens with the same face value (with 2 decimals)
        uint128[] memory period,    // staking period in seconds
        uint128[] memory rate       // percent per year with 2 decimals
     ) internal returns(bool) {
        
        require(amountETH.length == tokenMultiplier.length && rate.length == period.length && amountETH.length == rate.length, "Wrong length");
        
        uint256 bonusLength = options[vault].length;	
	    if(bonusLength > 0) delete options[vault];    // delete old options if exist        

        for (uint256 i = 0; i < amountETH.length; i++) {
            options[vault].push(Option(amountETH[i], tokenMultiplier[i], period[i], rate[i]));
        }
        
        return true;
    }


    function getOrder(address vault, address user) external view returns(Order memory order) {
        return stakingOrders[vault][user];
    }

    function stake(address vault, uint256 optionId, address user, uint256 amount) internal returns(bool) {
        
        require(optionId < options[vault].length, "Wrong option ID");
        require(amount > 0, "Amount can't be zero");

        Order memory o = Order(amount,0, block.timestamp, options[vault][optionId].period, options[vault][optionId].rate);
        uint256 reward = o.amount * o.period * o.rate / (SECONDS * RATE_NOMINATOR);
        o.reward = reward;
        stakingOrders[vault][user] = o;

        
        TokenVault(vault).transferToken(address(this),(amount + reward));
        emit Stake(vault, user, optionId, o.amount, o.startDate, o.period, o.rate);
        return true;
    }


    function withdraw(address vault) external returns(bool) {
        return _withdraw(vault, msg.sender);
    }

    function withdrawBehalf(address vault, address user) external returns(bool) {
        return _withdraw(vault, user);
    }

    // unstake and receive Token without APY (reward) if staking period is not end.
    function unstake(address vault) external returns(bool) {
        
        require(allowUnstake[vault], "Unsteke disallowed");
        
        Order memory o = stakingOrders[vault][msg.sender];
        
        if (block.timestamp > o.startDate + o.period) {
            return _withdraw(vault, msg.sender);
        }
        
        require(o.amount != 0, "Already withdrawn");
        
        address token = TokenVault(vault).token();
        safeTransfer(token,vault,o.reward);
        stakingOrders[vault][msg.sender].amount = 0;
        safeTransfer(token, msg.sender, o.amount);
        emit Unstake(vault, msg.sender, o.amount);
        return true;
    }
    
    function _withdraw(address vault, address user) internal returns(bool) {
        Order memory o = stakingOrders[vault][user];
        require(block.timestamp > o.startDate + o.period, "Staking not complete");
        require(o.amount != 0, "Already withdrawn");
        stakingOrders[vault][user].amount = 0;
        safeTransfer(TokenVault(vault).token(), user, o.amount + o.reward);
        emit WithdrawStaking(vault, user, o.amount + o.reward);
        return true;
    }
}


contract SendBonusETHValue is Staking {
    address constant ETH = address(2);  // eth address constant to get price from currency contract
    // user => tokenAddress => true/false
    mapping(address => mapping(address => bool)) public isTokenListed;
    
    mapping(address => mapping(address => uint256)) public receivedTokens; // vault => user => amount of token without APY reward
    
    address public system;  // system address can claim token on user behalf.

    address payable public company; // company address receive fee

    IPrice public priceFeed;    // currency price contract

    event CreateBonus(address indexed vault,address indexed token, uint256 amount, uint256 faceValue, address owner, uint256 payment,
        uint256[] amountETH,      
        uint256[] tokenMultiplier,    
        uint128[] period,    
        uint128[] rate );
    
    event UpdateFaceValue(address indexed vault, uint256 faceValue);

    modifier onlySystem() {
        require(msg.sender == system, "Caller is not the system");
        _;
    }

    modifier onlySystemOrOwner() {
        require(msg.sender == system || isOwner(), "Caller is not the system or owner");
        _;
    }

    constructor (address _system, address payable _company, address _priceFeed) {
        require(_company != address(0) && _system != address(0));
        system = _system;
        company = _company;
        priceFeed = IPrice(_priceFeed);
    }

    function setSystem(address _system) external onlyOwner returns(bool) {
        system = _system;
        return true;
    }
    
    function setCompany(address payable _company) external onlyOwner returns(bool) {
        require(_company != address(0));
        company = _company;
        return true;
    }

    function setPriceFeed(address _priceFeed) external onlyOwner returns(bool) {
        priceFeed = IPrice(_priceFeed);
        return true;
    }

    // set Deploy Fee (for Gas on ETH side)
    function setFee(uint256 _fee) external onlySystem returns(bool) {
        fee = _fee;
        return true;
    }

    function withdraw(address vault, address recipient, uint256 amount) external returns(bool) {
        require(msg.sender == vaultOwner[vault], "Caller is not the vault owner");
        TokenVault(vault).transferToken(recipient,amount);
        return true;
    }

    // allow vault owner update token face value if it's not listed on CoinGecko
    function updateFaceValue(address vault, uint256 faceValue) external returns(bool) {
        require(msg.sender == vaultOwner[vault], "Caller is not the vault owner");
        tokenFaceValue[address(vault)] = faceValue; // assign token face value by vault to avoid overriding. The face value with 9 decimals.
        emit UpdateFaceValue(vault, faceValue);
        return true;
    }

    function claimTokenBehalf(address vault, address user, uint256 amount, uint256 faceValue) external onlySystemOrOwner returns (bool) {
        
        address token = TokenVault(vault).token();
        require(receivedTokens[token][user] == 0, "User already received tokens");
        if (faceValue == 0) faceValue = tokenFaceValue[vault];
        require(faceValue != 0, "No face value");

        uint256 len = options[vault].length;
        
        while (len > 0) {
            len--;
            if(options[vault][len].amountETH == amount) {
                uint256 ethPrice = priceFeed.getCurrencyPrice(ETH);
                uint256 amountToken = amount * ethPrice * options[vault][len].tokenMultiplier / faceValue;
                receivedTokens[token][user] = amountToken;  // amount of token have to receive without APY
                if(options[vault][len].period == 0) {
                    TokenVault(vault).transferToken(user,amountToken);
                }
                else {
                    stake(vault, len, user, amountToken);
                }
                return true;
            }
        }
        revert("No appropriate stake options");
    }

    // create Bonus program by providing token supply and creating set of options by customer (bonusOwner)
    function createBonus(
        address token,      // token contract address
        uint256 amount,     // amount of tokens for bonus supply
        uint256 faceValue,  // token faceValue with 9 decimals
        uint256[] memory amountETH,      // amount of ETH that have to be send to request bonus
        uint256[] memory tokenMultiplier,    // multiply received USD amount by this value and send tokens with the same face value (with 2 decimals)
        uint128[] memory period,    // staking period in seconds
        uint128[] memory rate       // percent per year with 2 decimals
    ) external payable returns(bool) {
        require(msg.value >= fee, "Not enough Deploy fee");
        
        require(!isTokenListed[msg.sender][token],"token already listed by user");
        require(amount != 0, "Zero amount");
        
        TokenVault vault = new TokenVault(address(this),token);
        uint256 companyPart = msg.value - fee;
        if (companyPart !=0) safeTransferETH(company, companyPart);
        safeTransferETH(system, fee);// send fee to system wallet
        isTokenListed[msg.sender][token] = true;
        vaultOwner[address(vault)] = msg.sender;
        safeTransferFrom(token, msg.sender,address(vault), amount);
        tokenFaceValue[address(vault)] = faceValue; // assign token face value by vault to avoid overriding
        _createOptions(address(vault), amountETH, tokenMultiplier, period, rate);
        emit CreateBonus(address(vault),token, amount,faceValue,msg.sender, msg.value ,amountETH,tokenMultiplier,period,rate);
        return true;
    }
}