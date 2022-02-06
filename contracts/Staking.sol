// SPDX-License-Identifier: No License (None)
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

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

interface IBEP20 {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract Staking is Ownable {
    uint256 constant NOMINATOR = 10**18;    // rate nominator
    uint256 constant SECONDS = 31536000;    // number of seconde in a year (365 days)
    IBEP20 public token;
    uint256 public totalStakingAmount;

    event SetOption(uint256 id, uint128 period, uint128 rate);
    event RemoveOption(uint256 id, uint128 period, uint128 rate);
    event CreateOrder(address indexed user, uint256 id, uint256 amount, uint256 startDate, uint128 period, uint128 rate);
    event RemoveOrder(address indexed user, uint256 id, uint256 amount, uint256 startDate, uint128 period, uint128 rate);
    event UpdateOrder(address indexed user, uint256 id, uint256 amount, uint256 startDate, uint128 period, uint128 rate);
    event WithdrawStaking(address indexed user, uint256 amount);

    struct Option {
        uint128 period; // in seconds
        uint128 rate;   // rate with 18 decimals
    }

    Option[] options;

    struct Order {
        uint256 amount;
        uint256 startDate;
        uint128 period; // in seconds
        uint128 rate;   // rate with 18 decimals
    }

    mapping (address => Order[]) stakingOrders;

    constructor (address _token) {
        token = IBEP20(_token);
    }

    // Safe Math subtract function
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    // returns amount of tokens in reward pool
    function getRewardsPool() public view returns(uint256 rewardsPool) {
        return safeSub(token.balanceOf(address(this)),totalStakingAmount);
    }

    // returns number of available options
    function getNumberOptions() external view returns(uint256 number) {
        return options.length;
    }

    // returns all options
    function getOptions() external view returns(Option[] memory) {
        return options;
    }

    // returns selected option
    function getOption(uint256 id) external view returns(Option memory option) {
        return options[id];
    }


    // Create new staking option (staking rule).
    // period - in seconds
    // rate - percent per year with 18 decimals
    function addOption(uint128 period, uint128 rate) external onlyOwner returns(bool) {
        uint256 id = options.length;
        options.push(Option(period,rate));
        emit SetOption(id, period, rate);
        return true;
    }

    // Change existing stakin option (rule).
    // period - in seconds
    // rate - percent per year with 18 decimals
    // id - id of option to change
    function changeOption(uint128 period, uint128 rate, uint256 id) external onlyOwner returns(bool) {
        options[id].period = period;
        options[id].rate = rate;
        emit SetOption(id, period, rate);
        return true;
    }

    // Remove staking option
    // id - id of option to remove
    function removeOption(uint256 id) external onlyOwner returns(bool) {
        uint256 last = options.length - 1;
        require(id <= last, "Wrong order id");
        emit RemoveOption(id, options[id].period, options[id].rate);

        while (id < last) {
            options[id] = options[id+1];
            id++;
        }
        options.pop();
        return true;
    }

    // returns number of staking by user
    function getNumberOrders(address user) external view returns(uint256 number) {
        return stakingOrders[user].length;
    }

    // returns staking orders by user
    function getOrders(address user) external view returns(Order[] memory order) {
        return stakingOrders[user];
    }

    // returns selected staking order by user
    function getOrder(address user, uint256 id) external view returns(Order memory order) {
        return stakingOrders[user][id];
    }

    // returns amount of reward earned by user in selected staking order
    //user - address of user wallet
    //id - order id of user
    function calculateReward(address user, uint256 id) external view returns(uint256 reward) {
        (reward, ) = _calculateReward(user, id);
    }

    // Create new staking by user with selected option
    // optionId - staking option ID
    // amount - amount of tokens that user wants to stake
    function createOrder(uint256 optionId, uint256 amount) external returns(bool) {
        require(optionId < options.length, "Wrong option ID");
        require(amount > 0, "Amount can't be zero");
        token.transferFrom(msg.sender,address(this),amount);
        totalStakingAmount += amount;
        uint256 id = stakingOrders[msg.sender].length;

        Order memory order = Order(amount, block.timestamp, options[optionId].period, options[optionId].rate);
        stakingOrders[msg.sender].push(order);
        emit CreateOrder(msg.sender, id, order.amount, order.startDate, order.period, order.rate);
        return true;
    }

    // withdraw staking amount + rewards for selected order by user 
    function withdraw(uint256 id) external returns(bool) {
        (uint256 reward, bool complete) = _calculateReward(msg.sender, id);
        require(complete, "Staking not complete");
        require(getRewardsPool() >= reward, "Not enough tokens for reward");
        Order memory o = stakingOrders[msg.sender][id];
        totalStakingAmount = safeSub(totalStakingAmount, o.amount);
        token.transfer(msg.sender, o.amount + reward);
        _removeOrder(msg.sender, id);
        emit RemoveOrder(msg.sender, id, o.amount, o.startDate, o.period, o.rate);
        emit WithdrawStaking(msg.sender, o.amount + reward);
        return true;
    }

    // in case of empty rewards Pool user can withdraw tokens without reward
    function withdrawWithoutReward(uint256 id) external returns(bool) {
        (, bool complete) = _calculateReward(msg.sender, id);
        require(complete, "Staking not complete");
        Order memory o = stakingOrders[msg.sender][id];
        totalStakingAmount = safeSub(totalStakingAmount, o.amount);
        token.transfer(msg.sender, o.amount);
        _removeOrder(msg.sender, id);
        emit RemoveOrder(msg.sender, id, o.amount, o.startDate, o.period, o.rate);
        emit WithdrawStaking(msg.sender, o.amount);
        return true;
    }

    // user may change staking option to another with longer staking period
    // id - staking order id that user wants to upgrade
    // optionId - new option than user wants to use for his staking order
    function upgradeOrder(uint256 id, uint256 optionId) external returns(bool) {
        (uint256 reward, bool complete) = _calculateReward(msg.sender, id);
        require(!complete, "Staking complete");
        require(getRewardsPool() >= reward, "Not enough tokens for reward");
        require(optionId < options.length, "Wrong option ID");
        Order storage o = stakingOrders[msg.sender][id];
        Option memory opt = options[optionId];
        require(o.period < opt.period, "Not allowed change order to shorter period");
        totalStakingAmount += reward;
        o.amount = o.amount + reward;
        o.startDate = block.timestamp;
        o.period = opt.period;
        o.rate = opt.rate;
        emit UpdateOrder(msg.sender, id, o.amount, o.startDate, o.period, o.rate);
        return true;
    }

    // user can add more tokens to existing staking order
    // id - staking order where user wants to add token
    // amount - amount of tokens user wants to add
    function addToOrder(uint256 id, uint256 amount) external returns(bool) {
        (uint256 reward, bool complete) = _calculateReward(msg.sender, id);
        require(!complete, "Staking complete");
        require(getRewardsPool() >= reward, "Not enough tokens for reward");
        token.transferFrom(msg.sender,address(this),amount);
        totalStakingAmount = totalStakingAmount + amount + reward;
        Order storage o = stakingOrders[msg.sender][id];
        o.amount = o.amount + amount + reward;
        o.startDate = block.timestamp;
        emit UpdateOrder(msg.sender, id, o.amount, o.startDate, o.period, o.rate);
        return true;
    }

    function _removeOrder(address user, uint256 id) internal {
        uint256 last = stakingOrders[user].length - 1;
        require(id <= last, "Wrong order id");
        if (id < last) {
            stakingOrders[user][id] = stakingOrders[user][last];
        }
        stakingOrders[user].pop();
    }

    function _calculateReward(address user, uint256 id) internal view returns(uint256 reward, bool finished) {
        Order memory o = stakingOrders[user][id];
        uint256 timePassed = block.timestamp - o.startDate;
        if (timePassed > o.period) {
            timePassed = o.period;
            finished = true;
        }
        reward = o.amount * timePassed * o.rate / (100 * SECONDS * NOMINATOR);
    }
}
