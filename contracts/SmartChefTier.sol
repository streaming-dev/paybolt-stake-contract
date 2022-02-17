// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./interfaces/IBEP20.sol";
import "./interfaces/SafeBEP20.sol";
import "./interfaces/math/SafeMath.sol";
import "./interfaces/ReentrancyGuard.sol";
import "./interfaces/OwnableUpgradeable.sol";
import "./interfaces/IToken.sol";

contract PayboltStakingPool is OwnableUpgradeable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    struct UserPoolInfo {
        uint amount;     // How many LP tokens the user has provided.
        uint rewardDebt; // Reward debt. See explanation below.
        uint rewardFeeDebt; // Reward debt. See explanation below.
        uint timeDeposited;
    }

    // Info of each pool.
    struct PoolInfo {
        uint totalSupply;
        uint allocPoint;       // How many allocation points assigned to this pool. PAYs to distribute per block.
        uint minStakeAmount;   // How many tokens are deposited minimum
        uint timeLocked;       // How long stake must be locked for
        uint lastRewardBlock;  // Last block number that PAYs distribution occurs.
        uint accPayboltPerShare; // Accumulated PAYs per share, times 1e12. See below.
        uint accPayboltPerShareFromFees; // Accumulated PAYs per share, times 1e12. See below.
        uint lastAccPayboltFromFees; // last recorded total accumulated paybolt from fees
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint => mapping (address => UserPoolInfo)) public userPoolInfo;

    address public payboltFeeReceiver;
    address public payboltToken;
    uint public payboltPerBlock;
    uint public startBlock;

    uint public accWithdrawnPayboltFromFees;
    uint public accPayboltFromFees;
    uint public lastUpdatedPayboltFeesBlock;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalAllocPoint;

    uint public earlyWithdrawalFee;
    uint public constant EARLY_WITHDRAWAL_FEE_PRECISION = 1000000;
    uint public constant MAX_EARLY_WITHDRAWAL_FEE = 500000;

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EarlyWithdrawal(address indexed user, uint indexed pid, uint amount, uint withdrawalFee);
    event EmergencyWithdrawEarly(address indexed user, uint indexed pid, uint amount, uint withdrawalFee);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);
    event PoolAdded(uint allocPoint, uint timeLocked);
    event SetPayboltPerBlock(uint payboltPerBlock);
    event SetEarlyWithdrawalFee(uint earlyWithdrawalFee);
    event SetPoolAllocPoint(uint pid, uint allocPoint);
    event SetPoolMinStake(uint pid, uint minStakeAmount);
    event SetPoolTimeLocked(uint pid, uint timeLocked);

    function initialize(
        address _payboltToken,
        address _payboltFeeReceiver,
        uint _payboltPerBlock,
        uint _startBlock,
        uint _earlyWithdrawalFee
    ) external initializer {
        __Ownable_init();
        require(_earlyWithdrawalFee <= MAX_EARLY_WITHDRAWAL_FEE, "MAX_EARLY_WITHDRAWAL_FEE");
        payboltToken = _payboltToken;
        payboltFeeReceiver = _payboltFeeReceiver;
        payboltPerBlock = _payboltPerBlock;
        startBlock = _startBlock;
        earlyWithdrawalFee = _earlyWithdrawalFee;

        // staking pool
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 12000,
            minStakeAmount: uint(300).mul(IBEP20(payboltToken).decimals()),
            timeLocked: 90 days,
            lastRewardBlock: startBlock,
            accPayboltPerShare: 0,
            accPayboltPerShareFromFees: 0,
            lastAccPayboltFromFees: 0
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 8000,
            minStakeAmount: uint(150).mul(IBEP20(payboltToken).decimals()),
            timeLocked: 90 days,
            lastRewardBlock: startBlock,
            accPayboltPerShare: 0,
            accPayboltPerShareFromFees: 0,
            lastAccPayboltFromFees: 0
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 4000,
            minStakeAmount: uint(50).mul(IBEP20(payboltToken).decimals()),
            timeLocked: 90 days,
            lastRewardBlock: startBlock,
            accPayboltPerShare: 0,
            accPayboltPerShareFromFees: 0,
            lastAccPayboltFromFees: 0
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 1000,
            minStakeAmount: uint(5).mul(IBEP20(payboltToken).decimals()),
            timeLocked: 90 days,
            lastRewardBlock: startBlock,
            accPayboltPerShare: 0,
            accPayboltPerShareFromFees: 0,
            lastAccPayboltFromFees: 0
        }));
        totalAllocPoint = 25000;
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    /* ========== External Functions ========== */

    // View function to see pending PAYs from Pools on frontend.
    function pendingPaybolt(uint _pid, address _user) external view returns (uint) {
        PoolInfo memory pool = poolInfo[_pid];
        UserPoolInfo memory user = userPoolInfo[_pid][_user];

        // Minting reward
        uint accPayboltPerShare = pool.accPayboltPerShare;
        if (block.number > pool.lastRewardBlock && pool.totalSupply != 0) {
            uint multiplier = (block.number).sub(pool.lastRewardBlock);
            uint payboltReward = multiplier.mul(payboltPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accPayboltPerShare = accPayboltPerShare.add(payboltReward.mul(1e12).div(pool.totalSupply));
        }
        uint pendingUserPaybolt = user.amount.mul(accPayboltPerShare).div(1e12).sub(user.rewardDebt);

        // Transfer fee rewards
        uint _accPayboltFromFees = accPayboltFromFees;
        if (block.number > lastUpdatedPayboltFeesBlock) {
            uint payboltReceived = IBEP20(payboltToken).balanceOf(payboltFeeReceiver).add(accWithdrawnPayboltFromFees);
            if (payboltReceived.sub(_accPayboltFromFees) > 0) {
                _accPayboltFromFees = payboltReceived;
            }
        }
        if (pool.lastAccPayboltFromFees < _accPayboltFromFees && pool.totalSupply != 0) {
            uint payboltFeeReward = _accPayboltFromFees.sub(pool.lastAccPayboltFromFees).mul(pool.allocPoint).div(totalAllocPoint);
            uint accPayboltPerShareFromFees = pool.accPayboltPerShareFromFees.add(payboltFeeReward.mul(1e12).div(pool.totalSupply));
            uint pendingFeeReward = user.amount.mul(accPayboltPerShareFromFees).div(1e12).sub(user.rewardFeeDebt);
            pendingUserPaybolt = pendingUserPaybolt.add(pendingFeeReward);
        }

        return pendingUserPaybolt;
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (pool.totalSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        // Minting reward
        if (block.number > pool.lastRewardBlock && pool.totalSupply != 0) {
          uint multiplier = (block.number).sub(pool.lastRewardBlock);
          uint payboltReward = multiplier.mul(payboltPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
          pool.accPayboltPerShare = pool.accPayboltPerShare.add(payboltReward.mul(1e12).div(pool.totalSupply));
          pool.lastRewardBlock = block.number;
        }

        // Transfer fee rewards
        if (block.number > lastUpdatedPayboltFeesBlock) {
            uint payboltReceived = IBEP20(payboltToken).balanceOf(payboltFeeReceiver).add(accWithdrawnPayboltFromFees);
            if (payboltReceived.sub(accPayboltFromFees) > 0) {
                accPayboltFromFees = payboltReceived;
            }
            lastUpdatedPayboltFeesBlock = block.number;
        }
        if (pool.lastAccPayboltFromFees < accPayboltFromFees && pool.totalSupply != 0) {
            uint payboltFeeReward = accPayboltFromFees.sub(pool.lastAccPayboltFromFees).mul(pool.allocPoint).div(totalAllocPoint);
            pool.accPayboltPerShareFromFees = pool.accPayboltPerShareFromFees.add(payboltFeeReward.mul(1e12).div(pool.totalSupply));
            pool.lastAccPayboltFromFees = accPayboltFromFees;
        }
    }

    // Deposit PAY tokens for PAY allocation.
    function deposit(uint _pid, uint _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(_amount + user.amount > pool.minStakeAmount, "Should be greater then minimum stake amount");

        updatePool(_pid);
        if (user.amount > 0) {
            _claimPendingMintReward(_pid, msg.sender);
            _claimPendingFeeReward(_pid, msg.sender);
        }
        if (_amount > 0) {
            uint before = IBEP20(payboltToken).balanceOf(address(this));
            IBEP20(payboltToken).safeTransferFrom(address(msg.sender), address(this), _amount);
            uint post = IBEP20(payboltToken).balanceOf(address(this));
            uint finalAmount = post.sub(before);
            user.amount = user.amount.add(finalAmount);
            user.timeDeposited = block.timestamp;
            pool.totalSupply = pool.totalSupply.add(finalAmount);
            emit Deposit(msg.sender, _pid, finalAmount);
        }
        user.rewardDebt = user.amount.mul(pool.accPayboltPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accPayboltPerShareFromFees).div(1e12);
    }

    // Withdraw LP tokens
    function withdraw(uint _pid, uint _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(user.amount - _amount > pool.minStakeAmount, "Should be greater then minimum stake amount");
        require(user.amount >= _amount, "withdraw: not good");
        require(block.timestamp >= user.timeDeposited.add(pool.timeLocked), "time locked");

        updatePool(_pid);
        _claimPendingMintReward(_pid, msg.sender);
        _claimPendingFeeReward(_pid, msg.sender);

        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalSupply = pool.totalSupply.sub(_amount);
            IBEP20(payboltToken).safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPayboltPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accPayboltPerShareFromFees).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function withdrawEarly(uint _pid, uint _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        updatePool(_pid);

        _claimPendingMintReward(_pid, msg.sender);
        _claimPendingFeeReward(_pid, msg.sender);

        require(block.timestamp < user.timeDeposited.add(pool.timeLocked), "Not early");
        uint withdrawalFee = _amount.mul(earlyWithdrawalFee).div(EARLY_WITHDRAWAL_FEE_PRECISION);
        IBEP20(payboltToken).safeTransfer(address(msg.sender), _amount.sub(withdrawalFee));
        IBEP20(payboltToken).safeTransfer(payboltFeeReceiver, withdrawalFee);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accPayboltPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accPayboltPerShareFromFees).div(1e12);
        pool.totalSupply = pool.totalSupply.sub(_amount);
        emit EarlyWithdrawal(msg.sender, _pid, _amount, withdrawalFee);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(block.timestamp >= user.timeDeposited.add(pool.timeLocked), "time locked");

        uint amount = user.amount;

        pool.totalSupply = pool.totalSupply.sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardFeeDebt = 0;

        IBEP20(payboltToken).safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Withdraw early without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdrawEarly(uint _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];

        uint withdrawalFee = user.amount.mul(earlyWithdrawalFee).div(EARLY_WITHDRAWAL_FEE_PRECISION);
        uint amount = user.amount;

        pool.totalSupply = pool.totalSupply.sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardFeeDebt = 0;

        IBEP20(payboltToken).safeTransfer(address(msg.sender), amount.sub(withdrawalFee));
        IBEP20(payboltToken).safeTransfer(payboltFeeReceiver, withdrawalFee);

        emit EmergencyWithdrawEarly(msg.sender, _pid, amount, withdrawalFee);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(uint _allocPoint, uint _minStakeAmount, uint _timeLocked) external onlyOwner {
        massUpdatePools();
        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: _allocPoint,
            minStakeAmount: _minStakeAmount,
            timeLocked: _timeLocked,
            lastRewardBlock: lastRewardBlock,
            accPayboltPerShare: 0,
            accPayboltPerShareFromFees: 0,
            lastAccPayboltFromFees: accPayboltFromFees
        }));
        emit PoolAdded(_allocPoint, _timeLocked);
    }

    // Update the given pool's PAY allocation point. Can only be called by the owner.
    function setAllocPoint(uint _pid, uint _allocPoint) external onlyOwner {
        massUpdatePools();
        uint prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
        emit SetPoolAllocPoint(_pid, _allocPoint);
    }

    // Update the given pool's PAY minimum staked amount. Can only be called by the owner.
    function setMinStake(uint _pid, uint _minStakeAmount) external onlyOwner {
        require(_minStakeAmount > 0, "Should be greater zero!");
        massUpdatePools();
        poolInfo[_pid].minStakeAmount = _minStakeAmount;
        emit SetPoolMinStake(_pid, _minStakeAmount);
    }

    // Update the given pool's PAY locked time. Can only be called by the owner.
    function setTimeLocked(uint _pid, uint _timeLocked) external onlyOwner {
        massUpdatePools();
        poolInfo[_pid].timeLocked = _timeLocked;
        emit SetPoolTimeLocked(_pid, _timeLocked);
    }

    function setPayboltPerBlock(uint _payboltPerBlock) external onlyOwner {
        payboltPerBlock = _payboltPerBlock;
        emit SetPayboltPerBlock(_payboltPerBlock);
    }

    function setEarlyWithdrawalFee(uint _earlyWithdrawalFee) external onlyOwner {
        require(_earlyWithdrawalFee <= MAX_EARLY_WITHDRAWAL_FEE, "MAX_EARLY_WITHDRAWAL_FEE");
        earlyWithdrawalFee = _earlyWithdrawalFee;
        emit SetEarlyWithdrawalFee(earlyWithdrawalFee);
    }

    function _claimPendingMintReward(uint _pid, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][_user];

        uint pendingMintReward = user.amount.mul(pool.accPayboltPerShare).div(1e12).sub(user.rewardDebt);
        if (pendingMintReward > 0) {
            IToken(payboltToken).mint(_user, pendingMintReward);
        }
    }

    function _claimPendingFeeReward(uint _pid, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][_user];

        uint pendingFeeReward = user.amount.mul(pool.accPayboltPerShareFromFees).div(1e12).sub(user.rewardFeeDebt);
        if (pendingFeeReward > 0) {
            accWithdrawnPayboltFromFees = accWithdrawnPayboltFromFees.add(pendingFeeReward);
            transferFromFeeReceiver(_user, pendingFeeReward);
        }
    }

    function transferFromFeeReceiver(address to, uint amount) private {
        uint balance = IBEP20(payboltToken).balanceOf(payboltFeeReceiver);
        if (balance < amount) amount = balance;
        IBEP20(payboltToken).safeTransferFrom(payboltFeeReceiver, to, amount);
    }

}