
module sfarm::farming_pool {
    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::vec_map;
    use sui::coin:: {Self, Coin};
    use sui::tx_context:: {Self, TxContext};
    use sui::transfer;
    use sfarm::math;
    use sfarm::bignum;
    use std::vector;

    const FEE_DIVISOR: u64 = 10000;
    const SWAP_FEE: u64 = 25;
    const MINIMAL_LIQUIDITY: u64 = 1000;
    const PERCENT_FEE_TO_DAO: u64 = 3000;   // 20% of swap fee to DAO
    const MIN_LOCKED_DURATION: u64 = 2 * 7 * 86400;
    const ACC_REWARD_MULTIPLIER: u64 = 1000000000;

    const WEIGHT_MULTIPLIER: u64 = 1000000;
    const YEAR_STAKE_WEIGHT_MULTIPLIER: u64 = 2000000;
    const BONUS_MULTIPLIER: u64 = 5;
    const MAX_LOCKED_DURATION: u64 = 700 * 86400;

    /// ERROR CODE
    /// When coins used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 100;
    const ERR_INSUFFICIENT_PERMISSION: u64 = 101;
    const ERR_REWARD_BLOCK_INVALID: u64 = 102;
    const ERR_LOCK_DURATION_INVALID: u64 = 103;
    const ERR_POOL_REWARD_NOT_READY: u64 = 104;
    const ERR_REWARD_ALREADY_DEPSOTIED: u64 = 105;
    const ERR_EXCEED_MAX_LOCK_DURATION: u64 = 106;
    const ERR_DEPOSIT_ID_OUT_OF_RANGE: u64 = 107;
    const ERR_WITHDRAW_EXCEED: u64 = 108;
    const ERR_WITHDRAW_NOT_UNLOCK: u64 = 109;
    const ERR_NO_EMERGENCY: u64 = 110;

    //S: stake coin
    //R: reward coin
    struct FarmingPool<phantom S, phantom R> has key {
        id: UID,
        staked: Balance<S>,
        reward: Balance<R>,
        reward_coin_total: u64,
        reward_coin_deposited: u64,
        reward_coin_distributed: u64,
        pool_start_block: u64,
        pool_end_block: u64,
        reward_per_block: u64,
        acc_reward_per_share: u128,
        user_info: vec_map::VecMap<address, UserInfo>,
        min_locked_duration: u64,
        total_weight: u128,
        last_reward_block: u64,
        allow_emergency_withdraw: bool,
        dev_reward_multiplier: u64
    }

    struct UserInfo has copy, drop, store {
        staked_amount: u64,
        reward_debt: u64,
        staked_weight: u128,
        deposits: vector<Stake>
    }

    struct Stake has copy, drop, store {
        token_amount: u64,
        weight: u128,
        locked_from: u64,
        locked_till: u64
    }

    struct Admin has key {
        id: UID,
        owner: address,
        dev: address
    }

    fun init(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        transfer::share_object(Admin {
            id: object::new(ctx),
            owner: sender,
            dev: sender
        })
    }

    fun assert_owner(admin: &Admin, ctx: &TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(sender == admin.owner, ERR_INSUFFICIENT_PERMISSION);
    }

    public entry fun change_owner(admin: &mut Admin, new_owner: address, ctx: &mut TxContext) {
        assert_owner(admin, ctx);
        admin.owner = new_owner;
    }

    public entry fun change_dev(admin: &mut Admin, new_dev: address, ctx: &mut TxContext) {
        assert_owner(admin, ctx);
        admin.dev = new_dev;
    }

    public entry fun set_allow_emergency<S, R>(admin: &Admin, farming_pool: &mut FarmingPool<S, R>, val: bool, ctx: &mut TxContext) {
        assert_owner(admin, ctx);
        farming_pool.allow_emergency_withdraw = val;
    }

    public entry fun set_min_locked_duration<S, R>(admin: &Admin, farming_pool: &mut FarmingPool<S, R>, min_locked_duration: u64, ctx: &mut TxContext) {
        assert_owner(admin, ctx);
        farming_pool.min_locked_duration = min_locked_duration;
    }

    fun assert_pool_ready<S, R>(pool: &FarmingPool<S, R>) {
        assert!(pool.reward_coin_total > 0, ERR_POOL_REWARD_NOT_READY);
    }

    public entry fun add_pool<S, R>(
                                admin: &Admin, 
                                reward_coin_total: u64, 
                                pool_start_block: u64,
                                pool_end_block: u64,
                                min_locked_duration: u64,
                                dev_reward_multiplier: u64,
                                ctx: &mut TxContext) {
        assert_owner(admin, ctx);
        assert!(pool_end_block > pool_start_block, ERR_REWARD_BLOCK_INVALID);
        assert!(min_locked_duration >= MIN_LOCKED_DURATION, ERR_LOCK_DURATION_INVALID);
        
        transfer::share_object(FarmingPool {
            id: object::new(ctx),
            staked: balance::zero<S>(),
            reward: balance::zero<R>(),
            reward_coin_total: reward_coin_total,
            reward_coin_deposited: 0,
            reward_coin_distributed: 0,
            pool_start_block: pool_start_block,
            pool_end_block: pool_end_block,
            reward_per_block: reward_coin_total / (pool_end_block - pool_start_block),
            acc_reward_per_share: 0,
            user_info: vec_map::empty(),
            min_locked_duration: min_locked_duration,
            total_weight: 0,
            last_reward_block: 0,
            allow_emergency_withdraw: false,
            dev_reward_multiplier
        })
    }

    public entry fun deposit_pool_reward<S, R>(
                            pool: &mut FarmingPool<S, R>, 
                            reward_coin: Coin<R>,
                            ctx: &mut TxContext) {
        assert!(pool.reward_coin_deposited != pool.reward_coin_total, ERR_REWARD_ALREADY_DEPSOTIED);
        let reward_coin_balance = coin::into_balance(reward_coin);
        let reward_coin_input = coin::take(&mut reward_coin_balance, pool.reward_coin_total, ctx);
        let sender = tx_context::sender(ctx);
        transfer::transfer(coin::from_balance(reward_coin_balance, ctx), sender);
        coin::put(&mut pool.reward, reward_coin_input);
        pool.reward_coin_deposited = pool.reward_coin_total;
        let num_blocks = pool.pool_end_block - pool.pool_start_block;
        pool.pool_start_block = get_current_block_height();
        pool.pool_end_block = pool.pool_start_block + num_blocks;
        pool.last_reward_block = pool.pool_start_block;
    }

    // Update reward variables of the given pool to be up-to-date.
    fun update_pool<S, R>(
            admin: &Admin, 
            pool: &mut FarmingPool<S, R>, 
            ctx: &mut TxContext) {
        if (get_current_block_height() <= pool.last_reward_block || pool.last_reward_block == pool.pool_end_block) {
            return
        };

        if (pool.total_weight == 0) {
            pool.last_reward_block = get_current_block_height();
            return
        };

        let end_block = pool.pool_end_block;
        if (end_block > get_current_block_height()) {
            end_block = get_current_block_height();
        };

        let reward = pool.reward_per_block * (end_block - pool.last_reward_block);
        pool.last_reward_block = end_block;

        let dev_reward = math::mul_div(reward, pool.dev_reward_multiplier, FEE_DIVISOR);
        reward = reward - dev_reward;
        send_reward<R>(admin.dev, dev_reward, &mut pool.reward, ctx);

        let acc_credit = bignum::div(
                            bignum::mul(
                                bignum::from_u64(reward), 
                                bignum::from_u64(ACC_REWARD_MULTIPLIER)
                            ), 
                            bignum::from_u128(pool.total_weight)    
                        );
        pool.acc_reward_per_share = pool.acc_reward_per_share + bignum::as_u128(acc_credit);
    }

    public fun deposit<S, R>(
                    admin: &Admin,
                    pool: &mut FarmingPool<S, R>,
                    staker: address,
                    stake_coin: Coin<S>,
                    locked_duration: u64,
                    ctx: &mut TxContext) {
        assert_pool_ready(pool);
        assert!(locked_duration >= pool.min_locked_duration, ERR_LOCK_DURATION_INVALID);
        assert!(locked_duration <= MAX_LOCKED_DURATION, ERR_LOCK_DURATION_INVALID);
        update_pool<S, R>(admin, pool, ctx);

        let user = vec_map::get_mut(&mut pool.user_info, &staker);

        if (user.staked_amount > 0) {
            let pending_reward = bignum::as_u64(
                bignum::div(
                    bignum::mul(
                        bignum::from_u128(user.staked_weight),
                        bignum::from_u128(pool.acc_reward_per_share)
                    ),
                    bignum::from_u64(ACC_REWARD_MULTIPLIER)
                
                )
            );

            pending_reward = pending_reward - user.reward_debt;  
            send_reward<R>(staker, pending_reward, &mut pool.reward, ctx);
        };

        // merge stake coin
        let stake_coin_amount = coin::value(&stake_coin);
        coin::put(&mut pool.staked, stake_coin);
        let weight = (math::mul_to_u128(locked_duration,
         WEIGHT_MULTIPLIER) / ((365 * 86400) as u128) + (WEIGHT_MULTIPLIER as u128)) * (stake_coin_amount as u128);

        let current_time = get_current_block_timestamp();

        if (weight > 0) {
            vector::push_back(&mut user.deposits, Stake {
                token_amount: stake_coin_amount,
                weight: weight,
                locked_from: current_time,
                locked_till: current_time + locked_duration
            });
        };

        user.staked_amount = user.staked_amount + stake_coin_amount;
        user.staked_weight = user.staked_weight + weight;
        user.reward_debt = bignum::as_u64(
            bignum::div(
                bignum::mul(
                    bignum::from_u128(user.staked_weight),
                    bignum::from_u128(pool.acc_reward_per_share)
                ),
                bignum::from_u64(ACC_REWARD_MULTIPLIER)
            )
        );

        pool.total_weight = pool.total_weight + weight

        //emit deposit event
    }

    public entry fun deposit_script<S, R>(
                    admin: &Admin,
                    pool: &mut FarmingPool<S, R>,
                    stake_coin: Coin<S>,
                    stake_amount: u64,
                    locked_duration: u64,
                    ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let stake_balance = coin::into_balance(stake_coin);
        let stake_coin_input = coin::take(&mut stake_balance, stake_amount, ctx);
        transfer::transfer(coin::from_balance(stake_balance, ctx), sender);
        deposit(admin, pool, sender, stake_coin_input, locked_duration, ctx)
    }

    public entry fun withdraw<S, R>(
                    admin: &Admin,
                    pool: &mut FarmingPool<S, R>,
                    amount: u64,
                    deposit_id: u64,
                    ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        update_pool<S, R>(admin, pool, ctx);

        let user = vec_map::get_mut(&mut pool.user_info, &sender);
        assert!(vector::length(&user.deposits) > deposit_id, ERR_DEPOSIT_ID_OUT_OF_RANGE);
        let deposit = vector::borrow(&user.deposits, deposit_id);

        assert!(deposit.token_amount >= amount, ERR_WITHDRAW_EXCEED);
        assert!(deposit.locked_till < get_current_block_timestamp(), ERR_WITHDRAW_NOT_UNLOCK);
    
        let pending_reward = bignum::as_u64(
                bignum::div(
                    bignum::mul(
                        bignum::from_u128(user.staked_weight),
                        bignum::from_u128(pool.acc_reward_per_share)
                    ),
                    bignum::from_u64(ACC_REWARD_MULTIPLIER)
                
                )
            );
        send_reward<R>(sender, pending_reward, &mut pool.reward, ctx);

        let locked_duration = deposit.locked_till - deposit.locked_from;
        //update deposit
        let new_token_amount = deposit.token_amount - amount;
        let new_weight = (math::mul_to_u128(
                                locked_duration,
                                WEIGHT_MULTIPLIER) / ((365 * 86400) as u128) 
                                + (WEIGHT_MULTIPLIER as u128)) * (new_token_amount as u128);
        let previous_weight = deposit.weight;

        if (new_token_amount == 0) {
            vector::remove(&mut user.deposits, deposit_id);
        } else {
            let deposit = vector::borrow_mut<Stake>(&mut user.deposits, deposit_id);
            deposit.weight = new_weight;
            deposit.token_amount = new_token_amount;
        };

        user.staked_amount = user.staked_amount - amount;
        user.staked_weight = user.staked_weight + new_weight - previous_weight;
        user.reward_debt = bignum::as_u64(
            bignum::div(
                bignum::mul(
                    bignum::from_u128(user.staked_weight),
                    bignum::from_u128(pool.acc_reward_per_share)
                ),
                bignum::from_u64(ACC_REWARD_MULTIPLIER)
            )
        );

        pool.total_weight = pool.total_weight + new_weight - previous_weight;

        send_reward<S>(sender, amount, &mut pool.staked, ctx);

        //emit event
    }

    public entry fun emergency_withdraw<S, R>(pool: &mut FarmingPool<S, R>, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(pool.allow_emergency_withdraw, ERR_NO_EMERGENCY);
        let user = vec_map::get_mut(&mut pool.user_info, &sender);
        let amount = user.staked_amount;
        send_reward<S>(sender, amount, &mut pool.staked, ctx);
        pool.total_weight = pool.total_weight - user.staked_weight;
        user.staked_weight = 0;
        user.staked_amount = 0;
        user.deposits = vector::empty();
        user.reward_debt = 0;
    }

    fun send_reward<CoinType>(to_address: address, amount: u64, b: &mut Balance<CoinType>, ctx: &mut TxContext) {
        let reward_coin = coin::take(b, amount, ctx);
        transfer::transfer(reward_coin, to_address);
    }

    public fun get_user_info<S, R>(addr: address, pool: &FarmingPool<S, R>): 
                    (u64, u64, u128, vector<u64>, vector<u128>, vector<u64>, vector<u64>) {
        let user = vec_map::get(&pool.user_info, &addr);
        let token_amounts = vector::empty<u64>();
        let weights = vector::empty<u128>();
        let locked_froms = vector::empty<u64>();
        let locked_tills = vector::empty<u64>();

        let count = vector::length(&user.deposits);
        let i = 0;
        while (i < count) {
            let deposit = vector::borrow(&user.deposits, i);
            vector::push_back(&mut token_amounts, deposit.token_amount);
            vector::push_back(&mut weights, deposit.weight);
            vector::push_back(&mut locked_froms, deposit.locked_from);
            vector::push_back(&mut locked_tills, deposit.locked_till);
            i = i + 1;
        };

        (user.staked_amount, user.reward_debt, user.staked_weight, token_amounts, weights, locked_froms, locked_tills)
    }

    public fun get_deposit_info<S, R>(addr: address, deposit_id: u64, pool: &FarmingPool<S, R>): (u64, u128, u64, u64) {
        let user = vec_map::get(&pool.user_info, &addr);
        let deposit = vector::borrow(&user.deposits, deposit_id);
        (deposit.token_amount, deposit.weight, deposit.locked_from, deposit.locked_till)
    }

    public fun get_current_block_height(): u64 {
        return 0
    }

    public fun get_current_block_timestamp(): u64 {
        return 0
    }
}