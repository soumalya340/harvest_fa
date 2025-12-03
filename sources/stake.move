module harvest::stake {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;

    use aptos_std::event::{Self, EventHandle};
    use aptos_std::math64;
    use aptos_std::math128;
    use aptos_std::table;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_token::token::{Self, Token};

    // Fungible Asset (FA) framework imports for the new token standard.
    // FA uses Objects to represent token metadata and separate stores for token balances,
    // replacing the older Coin standard which used CoinStore<T> resources.
    use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset, FungibleStore};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, Object};

    use harvest::stake_config;

    //
    // Errors (same as before)
    //

    const ERR_NO_POOL: u64 = 100;
    const ERR_POOL_ALREADY_EXISTS: u64 = 101;
    const ERR_REWARD_CANNOT_BE_ZERO: u64 = 102;
    const ERR_NO_STAKE: u64 = 103;
    const ERR_NOT_ENOUGH_S_BALANCE: u64 = 104;
    const ERR_AMOUNT_CANNOT_BE_ZERO: u64 = 105;
    const ERR_NOTHING_TO_HARVEST: u64 = 106;
    const ERR_IS_NOT_COIN: u64 = 107;
    const ERR_TOO_EARLY_UNSTAKE: u64 = 108;
    const ERR_EMERGENCY: u64 = 109;
    const ERR_NO_EMERGENCY: u64 = 110;
    const ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY: u64 = 111;
    const ERR_DURATION_CANNOT_BE_ZERO: u64 = 112;
    const ERR_HARVEST_FINISHED: u64 = 113;
    const ERR_NOT_WITHDRAW_PERIOD: u64 = 114;
    const ERR_NOT_TREASURY: u64 = 115;
    const ERR_NO_COLLECTION: u64 = 116;
    const ERR_INVALID_BOOST_PERCENT: u64 = 117;
    const ERR_NON_BOOST_POOL: u64 = 118;
    const ERR_ALREADY_BOOSTED: u64 = 119;
    const ERR_WRONG_TOKEN_COLLECTION: u64 = 120;
    const ERR_NO_BOOST: u64 = 121;
    const ERR_NFT_AMOUNT_MORE_THAN_ONE: u64 = 122;
    const ERR_INVALID_REWARD_DECIMALS: u64 = 123;

    //
    // Constants (same as before)
    //

    const WEEK_IN_SECONDS: u64 = 604800;
    const WITHDRAW_REWARD_PERIOD_IN_SECONDS: u64 = 7257600;
    const MIN_NFT_BOOST_PRECENT: u128 = 1;
    const MAX_NFT_BOOST_PERCENT: u128 = 100;
    const ACCUM_REWARD_SCALE: u128 = 1000000000000;

    //
    // Core data structures
    //

    /// Staking pool for fungible assets. Under the Coin standard, the generic types S and R
    /// directly represented coin types. With Fungible Assets, these remain as phantom types
    /// for backward compatibility, but actual token identification is done via Metadata objects.
    struct StakePool<phantom S, phantom R> has key {
        // Metadata objects identify the fungible asset types for stake and reward tokens.
        // This replaces the Coin standard where type parameters alone identified the coin type.
        stake_metadata: Object<Metadata>, // Identifies stake token type
        reward_metadata: Object<Metadata>, // Identifies reward token type
        reward_per_sec: u64,
        accum_reward: u128,
        last_updated: u64,
        start_timestamp: u64,
        end_timestamp: u64,
        stakes: table::Table<address, UserStake>,

        // Addresses of secondary fungible stores that hold the pool's tokens.
        // Unlike Coin standard where coins were stored directly in resources,
        // FA requires separate FungibleStore objects to hold balances.
        stake_store: address, // Pool's stake token store
        reward_store: address, // Pool's reward token store
        scale: u128,
        total_boosted: u128,
        nft_boost_config: Option<NFTBoostConfig>,
        emergency_locked: bool,
        stake_events: EventHandle<StakeEvent>,
        unstake_events: EventHandle<UnstakeEvent>,
        deposit_events: EventHandle<DepositRewardEvent>,
        harvest_events: EventHandle<HarvestEvent>,
        boost_events: EventHandle<BoostEvent>,
        remove_boost_events: EventHandle<RemoveBoostEvent>
    }

    struct NFTBoostConfig has store {
        boost_percent: u128,
        collection_owner: address,
        collection_name: String
    }

    struct UserStake has store {
        amount: u64,
        unobtainable_reward: u128,
        earned_reward: u64,
        unlock_time: u64,
        nft: Option<Token>,
        boosted_amount: u128
    }

    //
    // Public functions
    //

    public fun create_boost_config(
        collection_owner: address, collection_name: String, boost_percent: u128
    ): NFTBoostConfig {
        assert!(
            token::check_collection_exists(collection_owner, collection_name),
            ERR_NO_COLLECTION
        );
        assert!(boost_percent >= MIN_NFT_BOOST_PRECENT, ERR_INVALID_BOOST_PERCENT);
        assert!(boost_percent <= MAX_NFT_BOOST_PERCENT, ERR_INVALID_BOOST_PERCENT);

        NFTBoostConfig { boost_percent, collection_owner, collection_name }
    }

    /// Registers a new staking pool with fungible assets. Key changes from Coin standard:
    /// - Accepts Metadata objects to identify token types (Coins used type parameters only)
    /// - Takes FungibleAsset instead of Coin<R> for initial rewards
    /// - Creates secondary FungibleStore objects to hold pool balances
    public fun register_pool<S, R>(
        owner: &signer,
        stake_metadata: Object<Metadata>, // Metadata object identifying the stake token type
        reward_metadata: Object<Metadata>, // Metadata object identifying the reward token type
        reward_coins: FungibleAsset, // Initial reward tokens (was Coin<R> in Coin standard)
        duration: u64,
        nft_boost_config: Option<NFTBoostConfig>
    ) {
        assert!(
            !exists<StakePool<S, R>>(signer::address_of(owner)),
            ERR_POOL_ALREADY_EXISTS
        );
        assert!(!stake_config::is_global_emergency(), ERR_EMERGENCY);
        assert!(duration > 0, ERR_DURATION_CANNOT_BE_ZERO);

        // Extract amount from FungibleAsset (replaces coin::value from Coin standard)
        let reward_per_sec = fungible_asset::amount(&reward_coins) / duration;
        assert!(reward_per_sec > 0, ERR_REWARD_CANNOT_BE_ZERO);

        let current_time = timestamp::now_seconds();
        let end_timestamp = current_time + duration;

        // Query decimals from Metadata object (Coin standard had decimals in CoinInfo resource)
        let reward_decimals = fungible_asset::decimals(reward_metadata);
        let origin_decimals = (reward_decimals as u128);
        assert!(origin_decimals <= 10, ERR_INVALID_REWARD_DECIMALS);

        let reward_scale = ACCUM_REWARD_SCALE / math128::pow(10, origin_decimals);
        let stake_decimals = fungible_asset::decimals(stake_metadata);
        let stake_scale = math128::pow(10, (stake_decimals as u128));
        let scale = stake_scale * reward_scale;

        // Create secondary fungible stores to hold pool's token balances.
        // In Coin standard, coins were stored as Coin<T> resources directly in structs.
        // FA standard requires separate FungibleStore objects created via the Object framework.
        let owner_addr = signer::address_of(owner);

        // Create stake store
        let stake_store_constructor = object::create_object(owner_addr);
        let stake_store =
            fungible_asset::create_store(&stake_store_constructor, stake_metadata);
        let stake_store_addr = object::object_address(&stake_store);

        // Create reward store
        let reward_store_constructor = object::create_object(owner_addr);
        let reward_store =
            fungible_asset::create_store(&reward_store_constructor, reward_metadata);
        let reward_store_addr = object::object_address(&reward_store);

        // Deposit initial rewards into the pool's reward store.
        // Coin standard would merge coins directly into a Coin<R> field.
        fungible_asset::deposit(reward_store, reward_coins);

        let pool = StakePool<S, R> {
            stake_metadata,
            reward_metadata,
            reward_per_sec,
            accum_reward: 0,
            last_updated: current_time,
            start_timestamp: current_time,
            end_timestamp,
            stakes: table::new(),
            stake_store: stake_store_addr,
            reward_store: reward_store_addr,
            scale,
            total_boosted: 0,
            nft_boost_config,
            emergency_locked: false,
            stake_events: account::new_event_handle<StakeEvent>(owner),
            unstake_events: account::new_event_handle<UnstakeEvent>(owner),
            deposit_events: account::new_event_handle<DepositRewardEvent>(owner),
            harvest_events: account::new_event_handle<HarvestEvent>(owner),
            boost_events: account::new_event_handle<BoostEvent>(owner),
            remove_boost_events: account::new_event_handle<RemoveBoostEvent>(owner)
        };
        move_to(owner, pool);
    }

    /// Deposits additional reward tokens to extend the pool duration.
    /// Changed from Coin<R> parameter to FungibleAsset to support FA standard.
    public fun deposit_reward_coins<S, R>(
        depositor: &signer, pool_addr: address, coins: FungibleAsset
    ) acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);
        assert!(!is_finished_inner(pool), ERR_HARVEST_FINISHED);

        // Extract amount from FungibleAsset (replaces coin::value)
        let amount = fungible_asset::amount(&coins);
        assert!(amount > 0, ERR_AMOUNT_CANNOT_BE_ZERO);

        let additional_duration = amount / pool.reward_per_sec;
        assert!(additional_duration > 0, ERR_DURATION_CANNOT_BE_ZERO);

        pool.end_timestamp = pool.end_timestamp + additional_duration;

        // Deposit tokens into the pool's reward store.
        // Coin standard used coin::merge to combine into Coin<R> resource.
        let reward_store = object::address_to_object<FungibleStore>(pool.reward_store);
        fungible_asset::deposit(reward_store, coins);

        let depositor_addr = signer::address_of(depositor);

        event::emit_event<DepositRewardEvent>(
            &mut pool.deposit_events,
            DepositRewardEvent {
                user_address: depositor_addr,
                amount,
                new_end_timestamp: pool.end_timestamp
            }
        );
    }

    /// Stakes fungible assets into the pool.
    /// Changed from Coin<S> parameter to FungibleAsset for FA standard compatibility.
    public fun stake<S, R>(
        user: &signer, pool_addr: address, coins: FungibleAsset
    ) acquires StakePool {
        let amount = fungible_asset::amount(&coins);
        assert!(amount > 0, ERR_AMOUNT_CANNOT_BE_ZERO);
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);
        assert!(!is_finished_inner(pool), ERR_HARVEST_FINISHED);

        update_accum_reward(pool);

        let current_time = timestamp::now_seconds();
        let user_address = signer::address_of(user);
        let accum_reward = pool.accum_reward;

        if (!table::contains(&pool.stakes, user_address)) {
            let new_stake = UserStake {
                amount,
                unobtainable_reward: 0,
                earned_reward: 0,
                unlock_time: current_time + WEEK_IN_SECONDS,
                nft: option::none(),
                boosted_amount: 0
            };

            new_stake.unobtainable_reward = (accum_reward * (amount as u128)) / pool.scale;
            table::add(&mut pool.stakes, user_address, new_stake);
        } else {
            let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
            update_user_earnings(accum_reward, pool.scale, user_stake);

            user_stake.amount = user_stake.amount + amount;

            if (option::is_some(&user_stake.nft)) {
                let boost_percent = option::borrow(&pool.nft_boost_config).boost_percent;
                pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
                user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent)
                    / 100;
                pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;
            };

            user_stake.unobtainable_reward =
                (accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;
            user_stake.unlock_time = current_time + WEEK_IN_SECONDS;
        };

        // Deposit staked tokens into the pool's stake store.
        // Coin standard would merge coins into a Coin<S> resource field.
        let stake_store = object::address_to_object<FungibleStore>(pool.stake_store);
        fungible_asset::deposit(stake_store, coins);

        event::emit_event<StakeEvent>(
            &mut pool.stake_events,
            StakeEvent { user_address, amount }
        );
    }

    /// Unstakes fungible assets from the pool and returns them to the user.
    /// Return type changed from Coin<S> to FungibleAsset for FA standard.
    public fun unstake<S, R>(
        user: &signer, pool_addr: address, amount: u64
    ): FungibleAsset acquires StakePool {
        assert!(amount > 0, ERR_AMOUNT_CANNOT_BE_ZERO);
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
        assert!(amount <= user_stake.amount, ERR_NOT_ENOUGH_S_BALANCE);

        let current_time = timestamp::now_seconds();
        if (pool.end_timestamp >= current_time) {
            assert!(current_time >= user_stake.unlock_time, ERR_TOO_EARLY_UNSTAKE);
        };

        update_user_earnings(pool.accum_reward, pool.scale, user_stake);

        user_stake.amount = user_stake.amount - amount;

        if (option::is_some(&user_stake.nft)) {
            let boost_percent = option::borrow(&pool.nft_boost_config).boost_percent;
            pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
            user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) /
                100;
            pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;
        };

        user_stake.unobtainable_reward =
            (pool.accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;

        event::emit_event<UnstakeEvent>(
            &mut pool.unstake_events,
            UnstakeEvent { user_address, amount }
        );

        // Withdraw tokens from pool's stake store and return as FungibleAsset.
        // Coin standard used coin::extract to remove coins from Coin<S> resource.
        let stake_store = object::address_to_object<FungibleStore>(pool.stake_store);
        fungible_asset::withdraw(user, stake_store, amount)
    }

    /// Harvests accumulated reward tokens and returns them to the user.
    /// Return type changed from Coin<R> to FungibleAsset for FA standard.
    public fun harvest<S, R>(user: &signer, pool_addr: address): FungibleAsset acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
        update_user_earnings(pool.accum_reward, pool.scale, user_stake);

        let earned = user_stake.earned_reward;
        assert!(earned > 0, ERR_NOTHING_TO_HARVEST);

        user_stake.earned_reward = 0;

        event::emit_event<HarvestEvent>(
            &mut pool.harvest_events,
            HarvestEvent { user_address, amount: earned }
        );

        // Withdraw reward tokens from pool's reward store and return as FungibleAsset.
        // Coin standard used coin::extract to remove coins from Coin<R> resource.
        let reward_store = object::address_to_object<FungibleStore>(pool.reward_store);
        fungible_asset::withdraw(user, reward_store, earned)
    }

    public fun boost<S, R>(user: &signer, pool_addr: address, nft: Token) acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);
        assert!(option::is_some(&pool.nft_boost_config), ERR_NON_BOOST_POOL);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        let token_amount = token::get_token_amount(&nft);
        assert!(token_amount == 1, ERR_NFT_AMOUNT_MORE_THAN_ONE);

        let token_id = token::get_token_id(&nft);
        let (token_collection_owner, token_collection_name, _, _) =
            token::get_token_id_fields(&token_id);

        let params = option::borrow(&pool.nft_boost_config);
        let boost_percent = params.boost_percent;
        let collection_owner = params.collection_owner;
        let collection_name = params.collection_name;

        assert!(token_collection_owner == collection_owner, ERR_WRONG_TOKEN_COLLECTION);
        assert!(token_collection_name == collection_name, ERR_WRONG_TOKEN_COLLECTION);

        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
        update_user_earnings(pool.accum_reward, pool.scale, user_stake);

        assert!(option::is_none(&user_stake.nft), ERR_ALREADY_BOOSTED);

        option::fill(&mut user_stake.nft, nft);

        user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) / 100;
        pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;

        user_stake.unobtainable_reward =
            (pool.accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;

        event::emit_event(
            &mut pool.boost_events,
            BoostEvent { user_address }
        );
    }

    public fun remove_boost<S, R>(user: &signer, pool_addr: address): Token acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
        assert!(option::is_some(&user_stake.nft), ERR_NO_BOOST);

        update_user_earnings(pool.accum_reward, pool.scale, user_stake);

        pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
        user_stake.boosted_amount = 0;

        user_stake.unobtainable_reward =
            (pool.accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;

        event::emit_event(
            &mut pool.remove_boost_events,
            RemoveBoostEvent { user_address }
        );

        option::extract(&mut user_stake.nft)
    }

    public fun enable_emergency<S, R>(admin: &signer, pool_addr: address) acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        assert!(
            signer::address_of(admin) == stake_config::get_emergency_admin_address(),
            ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        pool.emergency_locked = true;
    }

    /// Emergency unstake that bypasses normal restrictions and returns all staked tokens.
    /// Return type changed from (Coin<S>, Option<Token>) to (FungibleAsset, Option<Token>).
    public fun emergency_unstake<S, R>(
        user: &signer, pool_addr: address
    ): (FungibleAsset, Option<Token>) acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        assert!(is_emergency_inner(pool), ERR_NO_EMERGENCY);

        let user_addr = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);

        let user_stake = table::remove(&mut pool.stakes, user_addr);
        let UserStake {
            amount,
            unobtainable_reward: _,
            earned_reward: _,
            unlock_time: _,
            nft,
            boosted_amount: _
        } = user_stake;

        // Withdraw all staked tokens from pool's stake store.
        // Coin standard used coin::extract from Coin<S> resource.
        let stake_store = object::address_to_object<FungibleStore>(pool.stake_store);
        let coins = fungible_asset::withdraw(user, stake_store, amount);

        (coins, nft)
    }

    /// Allows treasury admin to withdraw unclaimed rewards after the withdrawal period.
    /// Return type changed from Coin<R> to FungibleAsset for FA standard.
    public fun withdraw_to_treasury<S, R>(
        treasury: &signer, pool_addr: address, amount: u64
    ): FungibleAsset acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        assert!(
            signer::address_of(treasury) == stake_config::get_treasury_admin_address(),
            ERR_NOT_TREASURY
        );

        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);

        if (!is_emergency_inner(pool)) {
            let now = timestamp::now_seconds();
            assert!(
                now >= (pool.end_timestamp + WITHDRAW_REWARD_PERIOD_IN_SECONDS),
                ERR_NOT_WITHDRAW_PERIOD
            );
        };

        // Withdraw reward tokens from pool's reward store.
        // Coin standard used coin::extract from Coin<R> resource.
        let reward_store = object::address_to_object<FungibleStore>(pool.reward_store);
        fungible_asset::withdraw(treasury, reward_store, amount)
    }

    //
    // Getter functions
    //

    public fun get_start_timestamp<S, R>(pool_addr: address): u64 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        pool.start_timestamp
    }

    public fun is_boostable<S, R>(pool_addr: address): bool acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        option::is_some(&pool.nft_boost_config)
    }

    public fun get_boost_config<S, R>(pool_addr: address): (address, String, u128) acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        assert!(option::is_some(&pool.nft_boost_config), ERR_NON_BOOST_POOL);

        let boost_config = option::borrow(&pool.nft_boost_config);
        (
            boost_config.collection_owner,
            boost_config.collection_name,
            boost_config.boost_percent
        )
    }

    public fun is_finished<S, R>(pool_addr: address): bool acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        is_finished_inner(pool)
    }

    public fun get_end_timestamp<S, R>(pool_addr: address): u64 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        pool.end_timestamp
    }

    public fun pool_exists<S, R>(pool_addr: address): bool {
        exists<StakePool<S, R>>(pool_addr)
    }

    public fun stake_exists<S, R>(pool_addr: address, user_addr: address): bool acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        table::contains(&pool.stakes, user_addr)
    }

    /// Returns the total amount of staked tokens in the pool.
    /// Changed to query balance from FungibleStore (Coin standard used coin::value).
    public fun get_pool_total_stake<S, R>(pool_addr: address): u64 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        let stake_store = object::address_to_object<FungibleStore>(pool.stake_store);
        fungible_asset::balance(stake_store)
    }

    public fun get_pool_total_boosted<S, R>(pool_addr: address): u128 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        borrow_global<StakePool<S, R>>(pool_addr).total_boosted
    }

    public fun get_user_stake<S, R>(
        pool_addr: address, user_addr: address
    ): u64 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);
        table::borrow(&pool.stakes, user_addr).amount
    }

    public fun is_boosted<S, R>(pool_addr: address, user_addr: address): bool acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);
        option::is_some(&table::borrow(&pool.stakes, user_addr).nft)
    }

    public fun get_user_boosted<S, R>(
        pool_addr: address, user_addr: address
    ): u128 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);
        table::borrow(&pool.stakes, user_addr).boosted_amount
    }

    public fun get_pending_user_rewards<S, R>(
        pool_addr: address, user_addr: address
    ): u64 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);

        let user_stake = table::borrow(&pool.stakes, user_addr);
        let current_time = get_time_for_last_update(pool);
        let new_accum_rewards = accum_rewards_since_last_updated(pool, current_time);

        let earned_since_last_update =
            user_earned_since_last_update(
                pool.accum_reward + new_accum_rewards,
                pool.scale,
                user_stake
            );
        user_stake.earned_reward + (earned_since_last_update as u64)
    }

    public fun get_unlock_time<S, R>(
        pool_addr: address, user_addr: address
    ): u64 acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);
        math64::min(
            pool.end_timestamp, table::borrow(&pool.stakes, user_addr).unlock_time
        )
    }

    public fun is_unlocked<S, R>(pool_addr: address, user_addr: address): bool acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);

        let current_time = timestamp::now_seconds();
        let unlock_time =
            math64::min(
                pool.end_timestamp,
                table::borrow(&pool.stakes, user_addr).unlock_time
            );
        current_time >= unlock_time
    }

    public fun is_emergency<S, R>(pool_addr: address): bool acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        is_emergency_inner(pool)
    }

    public fun is_local_emergency<S, R>(pool_addr: address): bool acquires StakePool {
        assert!(
            exists<StakePool<S, R>>(pool_addr),
            ERR_NO_POOL
        );
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        pool.emergency_locked
    }

    //
    // Private functions (mostly unchanged)
    //

    fun is_emergency_inner<S, R>(pool: &StakePool<S, R>): bool {
        pool.emergency_locked || stake_config::is_global_emergency()
    }

    fun is_finished_inner<S, R>(pool: &StakePool<S, R>): bool {
        let now = timestamp::now_seconds();
        now >= pool.end_timestamp
    }

    fun update_accum_reward<S, R>(pool: &mut StakePool<S, R>) {
        let current_time = get_time_for_last_update(pool);
        let new_accum_rewards = accum_rewards_since_last_updated(pool, current_time);

        pool.last_updated = current_time;

        if (new_accum_rewards != 0) {
            pool.accum_reward = pool.accum_reward + new_accum_rewards;
        };
    }

    fun accum_rewards_since_last_updated<S, R>(
        pool: &StakePool<S, R>, current_time: u64
    ): u128 {
        let seconds_passed = current_time - pool.last_updated;
        if (seconds_passed == 0) return 0;

        let total_boosted_stake = pool_total_staked_with_boosted(pool);
        if (total_boosted_stake == 0) return 0;

        let total_rewards = (pool.reward_per_sec as u128) * (seconds_passed as u128)
            * pool.scale;
        total_rewards / total_boosted_stake
    }

    fun update_user_earnings(
        accum_reward: u128, scale: u128, user_stake: &mut UserStake
    ) {
        let earned = user_earned_since_last_update(accum_reward, scale, user_stake);
        user_stake.earned_reward = user_stake.earned_reward + (earned as u64);
        user_stake.unobtainable_reward = user_stake.unobtainable_reward + earned;
    }

    fun user_earned_since_last_update(
        accum_reward: u128, scale: u128, user_stake: &UserStake
    ): u128 {
        ((accum_reward * user_stake_amount_with_boosted(user_stake)) / scale)
            - user_stake.unobtainable_reward
    }

    fun get_time_for_last_update<S, R>(pool: &StakePool<S, R>): u64 {
        math64::min(pool.end_timestamp, timestamp::now_seconds())
    }

    /// Calculates total staked amount including boost amounts.
    /// Changed to query balance from FungibleStore (Coin standard used coin::value).
    fun pool_total_staked_with_boosted<S, R>(pool: &StakePool<S, R>): u128 {
        let stake_store = object::address_to_object<FungibleStore>(pool.stake_store);
        (fungible_asset::balance(stake_store) as u128) + pool.total_boosted
    }

    fun user_stake_amount_with_boosted(user_stake: &UserStake): u128 {
        (user_stake.amount as u128) + user_stake.boosted_amount
    }

    //
    // Events (unchanged)
    //

    struct StakeEvent has drop, store {
        user_address: address,
        amount: u64
    }

    struct UnstakeEvent has drop, store {
        user_address: address,
        amount: u64
    }

    struct BoostEvent has drop, store {
        user_address: address
    }

    struct RemoveBoostEvent has drop, store {
        user_address: address
    }

    struct DepositRewardEvent has drop, store {
        user_address: address,
        amount: u64,
        new_end_timestamp: u64
    }

    struct HarvestEvent has drop, store {
        user_address: address,
        amount: u64
    }

    #[test_only]
    public fun get_unobtainable_reward<S, R>(
        pool_addr: address, user_addr: address
    ): u128 acquires StakePool {
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        table::borrow(&pool.stakes, user_addr).unobtainable_reward
    }

    #[test_only]
    public fun get_pool_info<S, R>(pool_addr: address): (u64, u128, u64, u64, u128) acquires StakePool {
        let pool = borrow_global<StakePool<S, R>>(pool_addr);
        let reward_store = object::address_to_object<FungibleStore>(pool.reward_store);
        (
            pool.reward_per_sec,
            pool.accum_reward,
            pool.last_updated,
            fungible_asset::balance(reward_store),
            pool.scale
        )
    }

    #[test_only]
    public fun recalculate_user_stake<S, R>(
        pool_addr: address, user_addr: address
    ) acquires StakePool {
        let pool = borrow_global_mut<StakePool<S, R>>(pool_addr);
        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
        update_user_earnings(pool.accum_reward, pool.scale, user_stake);
    }
}

