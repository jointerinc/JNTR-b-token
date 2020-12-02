// SPDX-License-Identifier: No License (None)
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

interface IBEP20 {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IPrice {
    function getCurrencyPrice(address _which) external view returns(uint256);   // 0 - BNB, 1 - ETH, 2 - BTC
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

abstract contract Staking is Ownable {
    uint256 constant RATE_NOMINATOR = 10000;    // rate nominator
    uint256 constant SECONDS = 31536000;    // number of seconde in a year (365 days)


    event CreateOption(address indexed token, uint256 payment);
    event Stake(address indexed token, address indexed user, uint256 optionId, uint256 amount, uint256 startDate, uint128 period, uint128 rate);
    event Unstake(address indexed token, address indexed user, uint256 amount);
    event WithdrawStaking(address indexed token, address indexed user, uint256 amount);

    struct Option {
        uint256 amountETH;      // amount of ETH that have to be send to request bonus
        uint256 amountToken;    // amount of Token that user will receive
        uint128 period; // staking period in seconds
        uint128 rate;   // rate with 2 decimals (i.e. 4570 = 45.7%)
    }

    struct Order {
        uint256 amount;
        uint256 startDate;
        uint128 period; // staking period in seconds
        uint128 rate;   // rate with 2 decimals (i.e. 4570 = 45.7%)
    }

    //IBEP20 public token;
    mapping (address => uint256) public totalStakingAmount; // by token
    mapping (address => address payable) public bonusOwners;
    mapping (address => bool) public allowUnstake;
    mapping (address => Option[]) options;   // token => Options. Options should be in order from lower `fromValue` to higher `fromValue`
    mapping (address => mapping (address => Order)) stakingOrders;  // token => user => Order

    // Safe Math subtract function
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    function safeTransfer(address token, address to, uint value) internal {
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

    function getRewardsPool(address token) public view returns(uint256 rewardsPool) {
        return safeSub(IBEP20(token).balanceOf(address(this)),totalStakingAmount[token]);
    }

    function getNumberOptions(address token) external view returns(uint256 number) {
        return options[token].length;
    }

    function getOptions(address token) external view returns(Option[] memory) {
        return options[token];
    }

    function getOption(address token, uint256 id) external view returns(Option memory option) {
        return options[token][id];
    }

    function setAllowUnstake(address token, bool _allowUnstake) external returns(bool) {
        require(msg.sender == bonusOwners[token], "Caller is not the bonusOwners");
        allowUnstake[token] = _allowUnstake;
        return true;
    }

    // allow bonus owner change address
    function changeBonusOwner(address token, address payable newBonusOwner) external returns(bool) {
        require(newBonusOwner != address(0));
        require(msg.sender == bonusOwners[token], "Caller is not the bonusOwners");
        bonusOwners[token] = newBonusOwner;
        return true;
    }

    // create set of options by customer (bonusOwner)
    function createOptions(
        address token,      // token contract address
        uint256[] memory amountETH,      // amount of ETH that have to be send to request bonus
        uint256[] memory amountToken,    // amount of Token that user will receive
        uint128[] memory period,    // staking period in seconds
        uint128[] memory rate       // percent per year with 2 decimals
    ) public payable returns(bool) {
        require(msg.sender == bonusOwners[token], "Caller is not the bonusOwners");
        require(amountETH.length == amountToken.length && rate.length == period.length && amountETH.length == rate.length, "Wrong length");
        if(options[token].length > 0) delete options[token];    // delete old options if exist
        for (uint256 i = 0; i < amountETH.length; i++) {
            options[token].push(Option(amountETH[i], amountToken[i], period[i], rate[i]));
        }
        emit CreateOption(token, msg.value);
        return true;
    }


    function getOrder(address token, address user) external view returns(Order memory order) {
        return stakingOrders[token][user];
    }

    function stake(address token, uint256 optionId, address user, uint256 amount) internal returns(bool) {
        require(optionId < options[token].length, "Wrong option ID");
        require(amount > 0, "Amount can't be zero");
        Order memory o = Order(amount, block.timestamp, options[token][optionId].period, options[token][optionId].rate);
        stakingOrders[token][user] = o;
        uint256 reward = o.amount * o.period * o.rate / (SECONDS * RATE_NOMINATOR);
        totalStakingAmount[token] += (amount + reward);
        require(IBEP20(token).balanceOf(address(this)) >= totalStakingAmount[token], "Not enough tokens in the pool");
        emit Stake(token, user, optionId, o.amount, o.startDate, o.period, o.rate);
        return true;
    }

    function withdraw(address token) external returns(bool) {
        return _withdraw(token, msg.sender);
    }

    function withdrawBehalf(address token, address user) external returns(bool) {
        return _withdraw(token, user);
    }

    // unstake and receive Token without APY (reward) if staking period is not end.
    function unstake(address token) external returns(bool) {
        require(allowUnstake[token], "Unsteke disallowed");
        Order memory o = stakingOrders[token][msg.sender];
        if (block.timestamp > o.startDate + o.period) {
            return _withdraw(token, msg.sender);
        }
        require(o.amount != 0, "Already withdrawn");
        uint256 reward = o.amount * o.period * o.rate / (SECONDS * RATE_NOMINATOR);
        totalStakingAmount[token] = safeSub(totalStakingAmount[token], (o.amount + reward));
        stakingOrders[token][msg.sender].amount = 0;
        safeTransfer(token, msg.sender, o.amount);
        emit Unstake(token, msg.sender, o.amount);
        return true;
    }

    function _withdraw(address token, address user) internal returns(bool) {
        Order memory o = stakingOrders[token][user];
        require(block.timestamp > o.startDate + o.period, "Staking not complete");
        require(o.amount != 0, "Already withdrawn");
        uint256 reward = o.amount * o.period * o.rate / (SECONDS * RATE_NOMINATOR);
        totalStakingAmount[token] = safeSub(totalStakingAmount[token], (o.amount + reward));
        stakingOrders[token][user].amount = 0;
        safeTransfer(token, user, o.amount + reward);
        emit WithdrawStaking(token, user, o.amount + reward);
        return true;
    }
}


contract SendBonusETH is Staking {

    uint256 public fee = 0.3 ether; // 0.3 BNB Deploy Fee (200,000 Gas on ETH)
    mapping(address => mapping(address => bool)) public isReceived; // token => user => isReceived
    address public system;  // system address can claim token on user behalf. 
    event CreateBonus(address indexed token, uint256 amount, address owner, uint256 payment);

    modifier onlySystem() {
        require(msg.sender == system, "Caller is not the system");
        _;
    }

    modifier onlySystemOrOwner() {
        require(msg.sender == system || isOwner(), "Caller is not the system or owner");
        _;
    }

    constructor (address _system) {
        system = _system;
    }

    function setSystem(address _system) external onlyOwner returns(bool) {
        system = _system;
        return true;
    }

    // set Deploy Fee (for Gas on ETH side)
    function setFee(uint256 _fee) external onlySystem returns(bool) {
        fee = _fee;
        return true;
    }

    function withdraw(address token, address recipient, uint256 amount) external returns(bool) {
        require(msg.sender == bonusOwners[token], "Caller is not the bonusOwners");
        require(getRewardsPool(token) >= amount, "Not enough tokens in the rewards pool");
        safeTransfer(token, recipient, amount);
        return true;
    }
   
    function claimTokenBehalf(address token, address user, uint256 amount) external onlySystemOrOwner returns (bool) {
        require(!isReceived[token][user], "User already received tokens");
        isReceived[token][user] = true;

        uint256 len = options[token].length;
        while (len > 0) {
            len--;
            if(options[token][len].amountETH == amount) {
                if(options[token][len].period == 0) {
                    safeTransfer(token, user, options[token][len].amountToken);
                }
                else {
                    stake(token, len, user, options[token][len].amountToken);
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
        uint256[] memory amountETH,      // amount of ETH that have to be send to request bonus
        uint256[] memory amountToken,    // amount of Token that user will receive
        uint128[] memory period,    // staking period in seconds
        uint128[] memory rate       // percent per year with 2 decimals
    ) external payable returns(bool) {
        require(msg.value >= fee, "Not enough Deploy fee");
        require(bonusOwners[token] == address(0), "Bonus program already created");
        require(amount != 0, "Zero amount");
        safeTransferETH(system, msg.value);     // send fee to system wallet
        bonusOwners[token] = msg.sender;
        safeTransferFrom(token, msg.sender, address(this), amount);
        createOptions(token, amountETH, amountToken, period, rate);
        emit CreateBonus(token, amount, msg.sender, msg.value);
        return true;
    }
}
