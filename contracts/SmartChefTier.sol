// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./interfaces/IBEP20.sol";
import "./interfaces/SafeBEP20.sol";
import "./interfaces/math/SafeMath.sol";
import "./interfaces/ReentrancyGuard.sol";
import "./interfaces/OwnableUpgradeable.sol";
import "./interfaces/IToken.sol";

contract PayboltStakingPool is OwnableUpgradeable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    struct UserPoolInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 timeDeposited; // When pool is deposited.
        uint256 timeClaimed; // When the reward token is claimed.
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 totalSupply;
        uint256 apr; // How many allocation points assigned to this pool. PAYs to distribute per block.
        uint256 minStakeAmount; // How many tokens are deposited minimum
        uint256 timeLocked; // How long stake must be locked for
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserPoolInfo)) public userPoolInfo;

    address public payboltToken;
    uint256 public totalRewardSupply;

    uint256 public constant PRECISION = 10000;
    uint256 private constant YEAR_TIME = 365 days;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event DepositAndUpdate(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event WithdrawAndUpdate(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event PoolAdded(uint256 apr, uint256 timeLocked);
    event SetPoolApr(uint256 pid, uint256 apr);
    event SetPoolMinStake(uint256 pid, uint256 minStakeAmount);
    event SetPoolTimeLocked(uint256 pid, uint256 timeLocked);
    event RewardTokenDeposited(uint256 amount);
    event Claimed(address user, uint256 pid, uint256 rewardAmount);
    event EmergencyWithdraw(address user, uint256 pid, uint256 amount);
    event RewardTokenWithdrawn(address user, uint256 amount);

    function initialize(address _payboltToken, uint256 _timeLocked)
        external
        initializer
    {
        __Ownable_init();
        payboltToken = _payboltToken;

        // staking pool
        poolInfo.push(
            PoolInfo({
                totalSupply: 0,
                apr: 1200,
                minStakeAmount: uint256(300).mul(
                    uint256(10)**IBEP20(payboltToken).decimals()
                ),
                timeLocked: _timeLocked
            })
        );
        poolInfo.push(
            PoolInfo({
                totalSupply: 0,
                apr: 800,
                minStakeAmount: uint256(150).mul(
                    uint256(10)**IBEP20(payboltToken).decimals()
                ),
                timeLocked: _timeLocked
            })
        );
        poolInfo.push(
            PoolInfo({
                totalSupply: 0,
                apr: 400,
                minStakeAmount: uint256(50).mul(
                    uint256(10)**IBEP20(payboltToken).decimals()
                ),
                timeLocked: _timeLocked
            })
        );
        poolInfo.push(
            PoolInfo({
                totalSupply: 0,
                apr: 100,
                minStakeAmount: uint256(5).mul(
                    uint256(10)**IBEP20(payboltToken).decimals()
                ),
                timeLocked: _timeLocked
            })
        );
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /* ========== External Functions ========== */

    // View function to see pending PAYs from Pools on frontend.
    function pendingReward(uint256 _pid, address _user)
        public
        view
        returns (uint256)
    {
        PoolInfo memory pool = poolInfo[_pid];
        UserPoolInfo memory user = userPoolInfo[_pid][_user];

        // Minting reward
        uint256 rewardDuration = 0;
        if (user.timeClaimed != 0) {
            rewardDuration = block.timestamp.sub(user.timeClaimed);
        }

        uint256 pendingUserPaybolt = user
            .amount
            .mul(rewardDuration)
            .mul(pool.apr)
            .div(PRECISION)
            .div(YEAR_TIME);
        return pendingUserPaybolt;
    }

    // Deposit PAY tokens for PAY allocation.
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(
            _amount + user.amount >= pool.minStakeAmount,
            "deposit: not good"
        );

        if (user.amount > 0) {
            _claimPendingReward(_pid, address(msg.sender));
        } else {
            user.timeDeposited = block.timestamp;
            user.timeClaimed = block.timestamp;
        }

        if (_amount > 0) {
            uint256 before = IBEP20(payboltToken).balanceOf(address(this));
            IBEP20(payboltToken).safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            uint256 post = IBEP20(payboltToken).balanceOf(address(this));
            uint256 finalAmount = post.sub(before);
            user.amount = user.amount.add(finalAmount);

            uint256 newPid = _getTierPid(user.amount);
            if (newPid == _pid) {
                pool.totalSupply = pool.totalSupply.add(finalAmount);
                emit Deposit(msg.sender, _pid, finalAmount);
            } else {
                PoolInfo storage newPool = poolInfo[newPid];
                UserPoolInfo storage newUser = userPoolInfo[newPid][msg.sender];

                newUser.amount = newUser.amount.add(user.amount);
                newUser.timeDeposited = user.timeDeposited;
                newUser.timeClaimed = block.timestamp;
                user.amount = 0;
                newPool.totalSupply = newPool.totalSupply.add(finalAmount);
                emit DepositAndUpdate(msg.sender, newPid, finalAmount);
            }
        }
    }

    // Withdraw tokens
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(
            block.timestamp >= user.timeDeposited + pool.timeLocked,
            "time locked"
        );
        require(user.amount - _amount >= 0, "withdraw: not good");

        if (user.amount > 0) {
            _claimPendingReward(_pid, address(msg.sender));
        }

        if (_amount > 0) {
            uint256 remain = user.amount.sub(_amount);
            uint256 newPid = _getTierPid(remain);

            if (newPid == _pid) {
                user.amount = remain;
                user.timeDeposited = block.timestamp;
                pool.totalSupply = pool.totalSupply.sub(_amount);
            } else {
                PoolInfo storage newPool = poolInfo[newPid];
                UserPoolInfo storage newUser = userPoolInfo[newPid][msg.sender];
                pool.totalSupply = pool.totalSupply.sub(user.amount);
                user.amount = 0;

                newUser.amount = newUser.amount.add(remain);
                newUser.timeDeposited = block.timestamp;
                newUser.timeClaimed = block.timestamp;
                newPool.totalSupply = newPool.totalSupply.add(remain);
                emit WithdrawAndUpdate(msg.sender, newPid, _amount);
            }

            IBEP20(payboltToken).safeTransfer(address(msg.sender), _amount);
        }
    }

    // claim reward tokens
    function _claimPendingReward(uint256 _pid, address _user) private {
        uint256 rewardAmount = pendingReward(_pid, _user);
        require(
            totalRewardSupply >= rewardAmount,
            "Should charge reward token"
        );

        totalRewardSupply = totalRewardSupply.sub(rewardAmount);
        IBEP20(payboltToken).safeTransfer(_user, rewardAmount);
        emit Claimed(_user, _pid, rewardAmount);
    }

    // get tier pid
    function _getTierPid(uint256 _amount) internal view returns (uint256) {
        uint256 pid = 0;
        for (uint256 i = poolInfo.length-1; i >= 0; i--) {
            if (
                i == 0 && _amount >= poolInfo[i].minStakeAmount
            ) {
                pid = i;
                break;
            }

            if (
                _amount >= poolInfo[i].minStakeAmount &&
                _amount < poolInfo[i - 1].minStakeAmount
            ) {
                pid = i;
                break;
            }
        }
        return pid;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(
        uint256 _apr,
        uint256 _minStakeAmount,
        uint256 _timeLocked
    ) external onlyOwner {
        poolInfo.push(
            PoolInfo({
                totalSupply: 0,
                apr: _apr,
                minStakeAmount: _minStakeAmount,
                timeLocked: _timeLocked
            })
        );
        emit PoolAdded(_apr, _timeLocked);
    }

    // Update the given pool's PAY allocation point. Can only be called by the owner.
    function setPoolApr(uint256 _pid, uint256 _apr) external onlyOwner {
        poolInfo[_pid].apr = _apr;
        emit SetPoolApr(_pid, _apr);
    }

    // Update the given pool's PAY minimum staked amount. Can only be called by the owner.
    function setMinStake(uint256 _pid, uint256 _minStakeAmount)
        external
        onlyOwner
    {
        require(_minStakeAmount > 0, "Should be greater zero!");
        poolInfo[_pid].minStakeAmount = _minStakeAmount;
        emit SetPoolMinStake(_pid, _minStakeAmount);
    }

    // Update the given pool's PAY locked time. Can only be called by the owner.
    function setTimeLocked(uint256 _pid, uint256 _timeLocked)
        external
        onlyOwner
    {
        poolInfo[_pid].timeLocked = _timeLocked;
        emit SetPoolTimeLocked(_pid, _timeLocked);
    }

    // Deposite tokens for reward
    function depositRewardToken(uint256 _amount) external onlyOwner {
        uint256 originalBalance = IBEP20(payboltToken).balanceOf(address(this));
        IBEP20(payboltToken).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
        uint256 currentBalance = IBEP20(payboltToken).balanceOf(address(this));
        require(
            originalBalance + _amount == currentBalance,
            "should-exclude-from-fee"
        );
        totalRewardSupply = totalRewardSupply.add(_amount);

        emit RewardTokenDeposited(_amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function withdrawRewardToken() external onlyOwner {
        uint256 amount = totalRewardSupply;
        totalRewardSupply = 0;
        IBEP20(payboltToken).safeTransfer(address(msg.sender), amount);
        emit RewardTokenWithdrawn(msg.sender, amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(
            block.timestamp >= user.timeDeposited.add(pool.timeLocked),
            "time locked"
        );

        uint256 amount = user.amount;

        pool.totalSupply = pool.totalSupply.sub(user.amount);
        user.amount = 0;

        IBEP20(payboltToken).safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }
}
