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
        uint timeDeposited;
    }

    // Info of each pool.
    struct PoolInfo {
        uint totalSupply;
        uint apr;       // How many allocation points assigned to this pool. PAYs to distribute per block.
        uint minStakeAmount;   // How many tokens are deposited minimum
        uint timeLocked;       // How long stake must be locked for
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint => mapping (address => UserPoolInfo)) public userPoolInfo;

    address public payboltToken;
    uint public totalRewardSupply;

    uint public constant PRECISION = 10000;
    uint private constant YEAR_TIME = 365 days;

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event PoolAdded(uint apr, uint timeLocked);
    event SetPoolApr(uint pid, uint apr);
    event SetPoolMinStake(uint pid, uint minStakeAmount);
    event SetPoolTimeLocked(uint pid, uint timeLocked);
    event RewardTokenDeposited(uint amount);

    function initialize(
        address _payboltToken,
        uint _timeLocked
    ) external initializer {
        __Ownable_init();
        payboltToken = _payboltToken;

        // staking pool
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            apr: 1200,
            minStakeAmount: uint(300).mul(IBEP20(payboltToken).decimals()),
            timeLocked: _timeLocked
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            apr: 800,
            minStakeAmount: uint(150).mul(IBEP20(payboltToken).decimals()),
            timeLocked: _timeLocked
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            apr: 400,
            minStakeAmount: uint(50).mul(IBEP20(payboltToken).decimals()),
            timeLocked: _timeLocked
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            apr: 100,
            minStakeAmount: uint(5).mul(IBEP20(payboltToken).decimals()),
            timeLocked: _timeLocked
        }));
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    /* ========== External Functions ========== */

    // View function to see pending PAYs from Pools on frontend.
    function pendingReward(uint _pid, address _user) public view returns (uint) {
        PoolInfo memory pool = poolInfo[_pid];
        UserPoolInfo memory user = userPoolInfo[_pid][_user];

        // Minting reward
        uint rewardDuration = 0;
        if(user.timeDeposited != 0) {
            rewardDuration = block.timestamp.sub(user.timeDeposited);
        }

        uint pendingUserPaybolt = user.amount.mul(rewardDuration).mul(pool.apr).div(PRECISION).div(YEAR_TIME);
        return pendingUserPaybolt;
    }

    // Deposit PAY tokens for PAY allocation.
    function deposit(uint _pid, uint _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(_amount >= pool.minStakeAmount && user.amount == 0, "deposit: not good");

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
    }

    // Withdraw LP tokens
    function withdraw(uint _pid, uint _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(user.amount == _amount, "withdraw: not good");
        require(block.timestamp >= user.timeDeposited.add(pool.timeLocked), "time locked");

        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalSupply = pool.totalSupply.sub(_amount);
            uint rewardAmount = pendingReward(_pid, msg.sender);

            require(totalRewardSupply >= rewardAmount, "Should charge reward token");
            totalRewardSupply = totalRewardSupply.sub(rewardAmount);
            IBEP20(payboltToken).safeTransfer(address(msg.sender), _amount.add(rewardAmount));
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(uint _apr, uint _minStakeAmount, uint _timeLocked) external onlyOwner {
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            apr: _apr,
            minStakeAmount: _minStakeAmount,
            timeLocked: _timeLocked
        }));
        emit PoolAdded(_apr, _timeLocked);
    }

    // Update the given pool's PAY allocation point. Can only be called by the owner.
    function setPoolApr(uint _pid, uint _apr) external onlyOwner {
        poolInfo[_pid].apr = _apr;
        emit SetPoolApr(_pid, _apr);
    }

    // Update the given pool's PAY minimum staked amount. Can only be called by the owner.
    function setMinStake(uint _pid, uint _minStakeAmount) external onlyOwner {
        require(_minStakeAmount > 0, "Should be greater zero!");
        poolInfo[_pid].minStakeAmount = _minStakeAmount;
        emit SetPoolMinStake(_pid, _minStakeAmount);
    }

    // Update the given pool's PAY locked time. Can only be called by the owner.
    function setTimeLocked(uint _pid, uint _timeLocked) external onlyOwner {
        poolInfo[_pid].timeLocked = _timeLocked;
        emit SetPoolTimeLocked(_pid, _timeLocked);
    }

    // Deposite tokens for reward
    function depositRewardToken(uint256 _amount) external nonReentrant {
        uint256 originalBalance = IBEP20(payboltToken).balanceOf(address(this));
        IBEP20(payboltToken).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 currentBalance = IBEP20(payboltToken).balanceOf(address(this));
        require(
            originalBalance + _amount == currentBalance,
            "should-exclude-from-fee"
        );
        totalRewardSupply = totalRewardSupply.add(_amount);

        emit RewardTokenDeposited(_amount);
    }

}