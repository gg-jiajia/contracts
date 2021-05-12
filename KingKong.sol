// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./interfaces/IKToken.sol";
import "./interfaces/IKingKong.sol";
import "./interfaces/IStrategy.sol";
import "./utils/StakeFrozenMap.sol";
import "./utils/BonusPoolMap.sol";

contract KingKong is IKingKong, Ownable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    using StakeFrozenMap for StakeFrozenMap.UintToUintMap;
    using BonusPoolMap for BonusPoolMap.UintToPoolMap;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Info of each user.
    struct UserInfo {
        uint shares;       // How many want tokens the user has provided.
        uint sharesFrozen; // How many want tokens the user has frozen.

        uint bonusDebt;
        uint rewardDebt;

        // We do some fancy math here. Basically, any point in time, the amount of KToken
        // entitled to a user but is pending to be distributed is:
        //
        //   amount = user.shares / sharesTotal * wantLockedTotal
        //   pending reward = (amount * pool.accPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
        //   1. The pool's `accPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `shares` gets updated.
        //   4. User's `debt` gets updated.

        // 累计的挖矿奖励
        uint accGains;

        // 累计的分红奖励
        uint accBonus;
    }

    struct PoolInfo {
        IERC20 want;     // Address of the want token.
        IStrategy strat; // Strategy address that will auto compound want tokens

        uint allocPoint;      // How many allocation points assigned to this pool. KToken to distribute per block.
        uint lastRewardBlock; // Last block number that KToken distribution occurs.

        uint accPerShare;     // Accumulated KToken per share, times 1e12. See below.
        uint frozenPeriod;

        // 累计的挖矿奖励
        uint accGains;

        // 累计的分红奖励
        uint accBonus;
    }

    BonusPoolMap.UintToPoolMap bonusPool;
    EnumerableSet.AddressSet whitelist;

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint => mapping(address => UserInfo)) public userInfo;
    mapping(uint => mapping(address => StakeFrozenMap.UintToUintMap)) frozenInfo;

    uint public constant blockOfWeek = 201600; // 24 * 60 * 60 * 7 / 3
    uint public constant startBlock  = 3200000;
    uint public constant KMaxSupply  = 85000000e18;

    address public KToken;
    address public ownerA;
    address public ownerB;

    uint public constant K_Per_Block  = 17361111111111111111;
    uint public ownerARate = 882;  // 7.5% = 10 / 85 * 0.75
    uint public ownerBRate = 294;  // 2.5%

    uint public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalBonusPoint = 0;

    bool private canSetReduceRate = true;
    uint private reduceRate = 900; // 100 = 10%

    // Events
    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // *** DO NOT add the same LP token more than once.
    // *** Rewards will be messed up if you do. (Only if want tokens are stored here.)
    function add(
        bool _withUpdate,
        bool _isOnlyStake,

        uint _allocPoint,
        uint _bonusPoint,
        uint _frozenPeriod,

        IERC20 _want,
        IStrategy _strat
    ) public override onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        if (_isOnlyStake) {
            totalBonusPoint = totalBonusPoint.add(_bonusPoint);
            bonusPool.set(poolInfo.length, BonusPoolMap.Bonus({
                strat:           address(_strat),
                allocPoint:      _bonusPoint,
                accPerShare:     0
            }));
        }

        poolInfo.push(
            PoolInfo({
                want:            _want,
                strat:           _strat,

                allocPoint:      _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accPerShare:     0,
                frozenPeriod:    _frozenPeriod,

                accGains: 0,
                accBonus: 0
            })
        );

        whitelist.add(address(_strat));
    }

    // Update the given pool's KToken allocation point. Can only be called by the owner.
    function set(
        bool _withUpdate,
        uint _pid,
        uint _allocPoint,
        uint _bonusPoint,
        uint _frozenPeriod
    ) public override onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
            _allocPoint
        );
        pool.allocPoint = _allocPoint;

        (bool isOnlyStake, BonusPoolMap.Bonus storage bonus) = bonusPool.tryGet(_pid);
        if (isOnlyStake) {
            totalBonusPoint = totalBonusPoint.sub(bonus.allocPoint).add(
                _bonusPoint
            );

            bonus.allocPoint = _bonusPoint;
            pool.frozenPeriod = _frozenPeriod;
        }
    }

    function phase(uint blockNumber) public pure returns (uint) {
        if (blockNumber > startBlock) {
            uint _phase = (blockNumber.sub(startBlock).sub(1)).div(blockOfWeek);
            if (_phase >= 10) {
                return 10;
            }
            return _phase;
        }
        return 0;
    }

    function reward(uint blockNumber) public view returns (uint) {
        uint _phase = phase(blockNumber);
        uint _reward = K_Per_Block;

        while (_phase > 0) {
            _phase--;
            _reward = _reward.mul(reduceRate).div(1000);
        }

        return _reward;
    }

    function getBlockReward(uint _lastRewardBlock) public view returns (uint) {
        if (IERC20(KToken).totalSupply() >= KMaxSupply) {
            return 0;
        }

        uint blockReward = 0;
        uint n = phase(_lastRewardBlock);
        uint m = phase(block.number);
        while (n < m) {
            n++;
            uint r = n.mul(blockOfWeek).add(startBlock);
            blockReward = blockReward.add((r.sub(_lastRewardBlock)).mul(reward(r)));
            _lastRewardBlock = r;
        }
        blockReward = blockReward.add((block.number.sub(_lastRewardBlock)).mul(reward(block.number)));
        return blockReward;
    }

    function calcProfit(uint _pid) internal view returns (uint, uint) {
        PoolInfo storage pool = poolInfo[_pid];
        (bool isOnlyStake, BonusPoolMap.Bonus storage bonus) = bonusPool.tryGet(_pid);

        if (isOnlyStake) {
            return (pool.accPerShare, bonus.accPerShare);
        }

        return (pool.accPerShare, 0);
    }

    // View function to see pending KToken on frontend.
    function pending(uint _pid, address _user)
        external
        override
        view
        returns (uint)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        (uint reward1, uint reward2) = calcProfit(_pid);
        uint sharesTotal = pool.strat.sharesTotal();

        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint blockReward = getBlockReward(pool.lastRewardBlock);
            uint KReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);

            reward1 = reward1.add(
                KReward.mul(1e12).div(sharesTotal)
            );
        }

        return user.shares.mul(reward1).div(1e12).sub(user.rewardDebt).add(
            user.shares.mul(reward2).div(1e12).sub(user.bonusDebt)
        );
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint _pid, address _user)
        external
        view
        returns (uint, uint)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[_pid][_user];

        uint len    = frozen.length();
        uint locked = user.sharesFrozen;

        while (len-- > 0) {
            (uint k, uint val) = frozen.at(len);
            if (block.number >= k) {
                locked = locked.sub(val);
            }
        }

        uint sharesTotal     = pool.strat.sharesTotal();
        uint wantLockedTotal = pool.strat.wantLockedTotal();

        if (sharesTotal == 0) {
            return (0, 0);
        }

        uint factor = wantLockedTotal.mul(1e12).div(sharesTotal);
        return (user.shares.mul(factor).div(1e12), locked.mul(factor).div(1e12));
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint sharesTotal = pool.strat.sharesTotal();
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint blockReward = getBlockReward(pool.lastRewardBlock);
        if (blockReward <= 0) {
            return;
        }

        uint gain = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
        if (gain > 0) {
            // Companion gain
            IKToken(KToken).mint(ownerA, gain.mul(ownerARate).div(10000));
            IKToken(KToken).mint(ownerB, gain.mul(ownerBRate).div(10000));

            // Minted KingKong token
            IKToken(KToken).mint(address(this), gain);

            pool.accPerShare = pool.accPerShare.add(
                gain.mul(1e12).div(sharesTotal)
            );

            // 累计总挖矿
            pool.accGains = pool.accGains.add(gain);
        }

        pool.lastRewardBlock = block.number;
    }

    function subFrozenStake(uint _pid, address _user) internal {
        UserInfo storage user = userInfo[_pid][_user];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[_pid][_user];

        uint len = frozen.length();
        while (len-- > 0) {
            (uint key, uint val) = frozen.at(len);

            if (block.number >= key) {
                user.sharesFrozen = user.sharesFrozen.sub(val);
                frozen.remove(key);
            }
        }
    }

    function addFrozenStake(uint _pid, address _user, uint _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[_pid][_user];

        uint frozenPeriod = pool.frozenPeriod.add(block.number);
        (bool exist, uint locked) = frozen.tryGet(frozenPeriod);

        if (exist) {
            frozen.set(frozenPeriod, locked.add(_amount));
        } else {
            frozen.set(frozenPeriod, _amount);
        }

        user.sharesFrozen = user.sharesFrozen.add(_amount);
    }

    // Want tokens moved from user -> AUTOFarm (KToken allocation) -> Strat (compounding)
    function deposit(uint _pid, uint _wantAmt) public override nonReentrant {
        updatePool(_pid);
        subFrozenStake(_pid, msg.sender);

        (uint reward1, uint reward2) = calcProfit(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.shares > 0) {
            uint gains = user.shares.mul(reward1).div(1e12).sub(user.rewardDebt);
            uint bonus = user.shares.mul(reward2).div(1e12).sub(user.bonusDebt);

            user.accGains = user.accGains.add(gains);
            user.accBonus = user.accBonus.add(bonus);

            if (gains.add(bonus) > 0) {
                safeKTransfer(msg.sender, gains.add(bonus));
            }
        }

        if (_wantAmt > 0) {
            // 1. user -> pool
            pool.want.safeTransferFrom(address(msg.sender), address(this), _wantAmt);
            // 2. pool -> strategy
            pool.want.safeIncreaseAllowance(address(pool.strat), _wantAmt);

            // 3. increase user shares
            uint sharesAdded = pool.strat.deposit(msg.sender, _wantAmt);
            user.shares = user.shares.add(sharesAdded);

            // 4. update frozen period
            if (bonusPool.contains(_pid)) {
                addFrozenStake(_pid, msg.sender, sharesAdded);
            }
        }

        user.rewardDebt = user.shares.mul(reward1).div(1e12);
        user.bonusDebt = user.shares.mul(reward2).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint _pid, uint _wantAmt) public override nonReentrant {
        updatePool(_pid);
        subFrozenStake(_pid, msg.sender);

        (uint reward1, uint reward2) = calcProfit(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint sharesTotal     = pool.strat.sharesTotal();
        uint wantLockedTotal = pool.strat.wantLockedTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        // Withdraw pending KToken
        {
            uint gains = user.shares.mul(reward1).div(1e12).sub(user.rewardDebt);
            uint bonus = user.shares.mul(reward2).div(1e12).sub(user.bonusDebt);

            user.accGains = user.accGains.add(gains);
            user.accBonus = user.accBonus.add(bonus);

            if (gains.add(bonus) > 0) {
                safeKTransfer(msg.sender, gains.add(bonus));
            }
        }

        // Withdraw want tokens
        uint amount =
            user.shares.sub(user.sharesFrozen).mul(wantLockedTotal).div(
                sharesTotal
            );

        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint sharesRemoved = pool.strat.withdraw(msg.sender, _wantAmt);

            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint wantBal = pool.want.balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            pool.want.safeTransfer(address(msg.sender), _wantAmt);
        }

        user.rewardDebt = user.shares.mul(reward1).div(1e12);
        user.bonusDebt = user.shares.mul(reward2).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    function withdrawAll(uint _pid) public {
        withdraw(_pid, uint(-1));
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) public override {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint sharesTotal = pool.strat.sharesTotal();
        require(sharesTotal > 0, "sharesTotal is 0");

        uint wantLockedTotal = pool.strat.wantLockedTotal();
        uint amount =
            user.shares.sub(user.sharesFrozen).mul(wantLockedTotal).div(
                sharesTotal
            );

        if (amount > 0) {
            pool.strat.withdraw(msg.sender, amount);
            pool.want.safeTransfer(msg.sender, amount);

            user.shares     = 0;
            user.rewardDebt = 0;
            user.bonusDebt  = 0;
            user.accGains   = 0;
            user.accBonus   = 0;

            emit EmergencyWithdraw(msg.sender, _pid, amount);
        }
    }

    // Safe KToken transfer function, just in case if rounding error causes pool to not have enough
    function safeKTransfer(address _to, uint _amount) internal {
        uint KBal = IERC20(KToken).balanceOf(address(this));
        if (_amount > KBal) {
            IERC20(KToken).transfer(_to, KBal);
        } else {
            IERC20(KToken).transfer(_to, _amount);
        }
    }

    function inCaseTokensGetStuck(address _token, uint _amount) public onlyOwner {
        require(_token != KToken, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function transmitBuyback(uint _amount) external override {
        require(whitelist.contains(msg.sender), "invalid strategy");

        uint length = bonusPool.length();
        for (uint i = 0; i < length; i++) {
            (, BonusPoolMap.Bonus storage bonus) = bonusPool.at(i);

            uint gain = _amount.mul(bonus.allocPoint).div(totalBonusPoint);
            uint sharesTotal = IStrategy(bonus.strat).sharesTotal();

            if (sharesTotal > 0) {
                bonus.accPerShare = bonus.accPerShare.add(
                    gain.mul(1e12).div(sharesTotal)
                );
            }
        }
    }

    event SetAddresses(address indexed token, address indexed team1, address indexed team2);
    function setAddresses(address token_, address team1_, address team2_) public onlyOwner {
        require(token_ != address(0), "Zero address");
        require(team1_ != address(0), "Zero address");
        require(team2_ != address(0), "Zero address");

        KToken = token_;
        ownerA = team1_;
        ownerB = team2_;

        emit SetAddresses(token_, team1_, team2_);
    }

    event SetOwnerRate(uint indexed a, uint indexed b);
    function setOwnerRate(uint a, uint b) public onlyOwner {
        ownerARate = a;
        ownerBRate = b;
        emit SetOwnerRate(a, b);
    }

    event SetReduceRate(uint indexed rate);
    function setReduceRate(uint _rate) public onlyOwner {
        if (canSetReduceRate) {
            reduceRate = _rate;
            emit SetReduceRate(_rate);
        }
    }

    event RenounceSetReduceRate(bool indexed status);
    function renounceSetReduceRate() public onlyOwner {
        if (canSetReduceRate) {
            canSetReduceRate = false;
            emit RenounceSetReduceRate(canSetReduceRate);
        }
    }

    function inspectUserInfo(uint pid_, address user_)
        public
        view
        returns (
            uint shares_,
            uint sharesFrozen_,
            uint bonusDebt_,
            uint rewardDebt_,
            uint[] memory k_,
            uint[] memory v_
        )
    {
        UserInfo storage user = userInfo[pid_][user_];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[pid_][user_];

        shares_       = user.shares;
        sharesFrozen_ = user.sharesFrozen;
        bonusDebt_    = user.bonusDebt;
        rewardDebt_   = user.rewardDebt;

        uint len = frozen.length();
        k_ = new uint[](len);
        v_ = new uint[](len);

        for (uint i = 0; i < len; i++) {
            (uint k, uint v) = frozen.at(i);

            k_[i] = k;
            v_[i] = v;
        }
    }
}
