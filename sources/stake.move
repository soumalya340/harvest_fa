module harvest::stake {

    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_framework::string_utils;
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::math64;
    use aptos_std::math128;
    use aptos_std::table;
    use aptos_framework::account;
    use aptos_framework::timestamp;

    // OLD NFT Standard (v1)
    use aptos_token::token::{Self, Token as LegacyToken};

    // NEW NFT Standard (v2) - Digital Assets
    use aptos_token_objects::token::Token as DigitalAssetToken;
    use aptos_token_objects::token as da_token; // da = digital asset

    use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_std::table::Table;

    use harvest::resource_account as resource_account_module;
    use harvest::stake_config as stake_config_module;

    //==============================================================================================
    // Error codes
    //==============================================================================================

    const ERR_NO_POOL: u64 = 100;
    const ERR_POOL_ALREADY_EXISTS: u64 = 101;
    const ERR_REWARD_CANNOT_BE_ZERO: u64 = 102;
    const ERR_NO_STAKE: u64 = 103;
    const ERR_NOT_ENOUGH_S_BALANCE: u64 = 104;
    const ERR_AMOUNT_CANNOT_BE_ZERO: u64 = 105;
    const ERR_NOTHING_TO_HARVEST: u64 = 106;
    const ERR_TOO_EARLY_UNSTAKE: u64 = 108;
    const ERR_EMERGENCY: u64 = 109;
    const ERR_NO_EMERGENCY: u64 = 110;
    const ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY: u64 = 111;
    const ERR_DURATION_CANNOT_BE_ZERO: u64 = 112;
    const ERR_HARVEST_FINISHED: u64 = 113;
    const ERR_NOT_WITHDRAW_PERIOD: u64 = 114;
    const ERR_NOT_TREASURY: u64 = 115;
    const ERR_INVALID_BOOST_PERCENT: u64 = 117;
    const ERR_NON_BOOST_POOL: u64 = 118;
    const ERR_ALREADY_BOOSTED: u64 = 119;
    const ERR_WRONG_TOKEN_COLLECTION: u64 = 120;
    const ERR_NO_BOOST: u64 = 121;
    const ERR_NFT_AMOUNT_MORE_THAN_ONE: u64 = 122;
    const ERR_WRONG_VERSION: u64 = 124;
    const ERR_NOT_OWNER: u64 = 126;
    const ERR_INVALID_REWARD_DECIMALS: u64 = 127;

    //==============================================================================================
    // Constants
    //==============================================================================================

    const WEEK_IN_SECONDS: u64 = 604800;
    const WITHDRAW_REWARD_PERIOD_IN_SECONDS: u64 = 7257600;
    const MIN_NFT_BOOST_PRECENT: u128 = 1;
    const MAX_NFT_BOOST_PERCENT: u128 = 100;
    const ACCUM_REWARD_SCALE: u128 = 1000000000000;

    /// NFT Version Constants
    const NFT_VERSION_V1: u64 = 1; // Old Token standard
    const NFT_VERSION_V2: u64 = 2; // New Digital Assets standard

    //==============================================================================================
    // Structs
    //==============================================================================================

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct StakePool has key {
        pool_creator: address,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_per_sec: u64,
        accum_reward: u128,
        last_updated: u64,
        start_timestamp: u64,
        end_timestamp: u64,
        stakes: table::Table<address, UserStake>,
        stake_amount: u64,
        reward_amount: u64,
        extend_ref: ExtendRef,
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

    /// NFT Boost Configuration
    /// version: 1 = old Token standard, 2 = new Digital Assets standard
    struct NFTBoostConfig has store {
        boost_percent: u128,
        version: u64,
        collection_identifier: address, // v1: creator address, v2: collection object address
        collection_name: String // Used for v1 validation, stored for reference in v2
    }

    /// User's stake information
    struct UserStake has store {
        amount: u64,
        unobtainable_reward: u128,
        earned_reward: u64,
        unlock_time: u64,
        // OLD standard NFT (stored directly)
        nft_v1: Option<LegacyToken>,
        // NEW standard NFT (stored as object address, NFT transferred to pool)
        nft_v2_address: Option<address>,
        boosted_amount: u128
    }

    struct AllPoolInfos has key {
        total_count: u128,
        pool_infos: Table<u128, PoolInfo>
    }

    struct PoolInfo has store {
        pool_address: address,
        stake_coin_name: String,
        reward_coin_name: String
    }

    //==============================================================================================
    // Module Initialization
    //==============================================================================================

    fun init_module(deployer: &signer) {
        move_to(
            deployer,
            AllPoolInfos { total_count: 0, pool_infos: table::new() }
        );
    }

    //==============================================================================================
    // Helper Functions
    //==============================================================================================

    fun get_seed(
        stake_metadata: Object<Metadata>, reward_metadata: Object<Metadata>
    ): (vector<u8>, String, String) {
        let seed = b"StakePool::";
        let stake_addr = object::object_address(&stake_metadata);
        let reward_addr = object::object_address(&reward_metadata);
        let reward_addr_string = string_utils::to_string(&stake_addr);
        let stake_addr_string = string_utils::to_string(&reward_addr);
        std::vector::append(&mut seed, *std::string::bytes(&reward_addr_string));
        std::vector::append(&mut seed, b"::");
        std::vector::append(&mut seed, *std::string::bytes(&stake_addr_string));
        (seed, stake_addr_string, reward_addr_string)
    }

    fun get_pool_address(
        stake_metadata: Object<Metadata>, reward_metadata: Object<Metadata>
    ): address {
        let resource_account_addr =
            resource_account_module::get_resource_account_address();
        let (seed, _, _) = get_seed(stake_metadata, reward_metadata);
        object::create_object_address(&resource_account_addr, seed)
    }

    fun get_pool_signer(pool_addr: address): signer acquires StakePool {
        let pool = borrow_global<StakePool>(pool_addr);
        object::generate_signer_for_extending(&pool.extend_ref)
    }

    fun get_pool_signer_internal(extend_ref: &ExtendRef): signer {
        object::generate_signer_for_extending(extend_ref)
    }

    //==============================================================================================
    // Pool Creation
    //==============================================================================================

    /// Create NFT boost configuration
    /// version: 1 for old Token standard, 2 for new Digital Assets standard
    /// collection_identifier:
    ///   - For v1: the collection creator's address
    ///   - For v2: the collection object's address
    public fun create_boost_config(
        version: u64,
        collection_identifier: address,
        collection_name: String,
        boost_percent: u128
    ): NFTBoostConfig {
        assert!(
            version == NFT_VERSION_V1 || version == NFT_VERSION_V2,
            ERR_WRONG_VERSION
        );
        assert!(
            boost_percent >= MIN_NFT_BOOST_PRECENT
                && boost_percent <= MAX_NFT_BOOST_PERCENT,
            ERR_INVALID_BOOST_PERCENT
        );
        NFTBoostConfig { boost_percent, version, collection_identifier, collection_name }
    }

    /// Register a new staking pool
    public fun register_pool(
        owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_coins: FungibleAsset,
        duration: u64,
        nft_boost_config: Option<NFTBoostConfig>
    ) acquires AllPoolInfos {
        let owner_addr = signer::address_of(owner);
        let resource_account_signer =
            resource_account_module::get_resource_account_signer();

        // Create unique seed
        let (seed, stake_addr_string, reward_addr_string) =
            get_seed(stake_metadata, reward_metadata);

        let constructor_ref = object::create_named_object(
            &resource_account_signer, seed
        );
        let pool_addr = get_pool_address(stake_metadata, reward_metadata);

        assert!(!exists<StakePool>(pool_addr), ERR_POOL_ALREADY_EXISTS);
        assert!(duration > 0, ERR_DURATION_CANNOT_BE_ZERO);

        let reward_amount = fungible_asset::amount(&reward_coins);
        let reward_per_sec = reward_amount / duration;
        assert!(reward_per_sec > 0, ERR_REWARD_CANNOT_BE_ZERO);

        let current_time = timestamp::now_seconds();
        let end_timestamp = current_time + duration;

        // Calculate scale
        let reward_decimals = fungible_asset::decimals(reward_metadata);
        let origin_decimals = (reward_decimals as u128);
        assert!(origin_decimals <= 10, ERR_INVALID_REWARD_DECIMALS);

        let reward_scale = ACCUM_REWARD_SCALE / math128::pow(10, origin_decimals);
        let stake_decimals = fungible_asset::decimals(stake_metadata);
        let stake_scale = math128::pow(10, (stake_decimals as u128));
        let scale = stake_scale * reward_scale;

        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        // Deposit rewards to pool
        primary_fungible_store::deposit(pool_addr, reward_coins);

        let pool = StakePool {
            pool_creator: owner_addr,
            stake_metadata,
            reward_metadata,
            reward_per_sec,
            accum_reward: 0,
            last_updated: current_time,
            start_timestamp: current_time,
            end_timestamp,
            stakes: table::new(),
            stake_amount: 0,
            reward_amount,
            extend_ref,
            scale,
            total_boosted: 0,
            nft_boost_config,
            emergency_locked: false,
            stake_events: account::new_event_handle<StakeEvent>(&object_signer),
            unstake_events: account::new_event_handle<UnstakeEvent>(&object_signer),
            deposit_events: account::new_event_handle<DepositRewardEvent>(&object_signer),
            harvest_events: account::new_event_handle<HarvestEvent>(&object_signer),
            boost_events: account::new_event_handle<BoostEvent>(&object_signer),
            remove_boost_events: account::new_event_handle<RemoveBoostEvent>(
                &object_signer
            )
        };

        move_to(&object_signer, pool);

        // Register in pool infos
        let all_pool_infos = borrow_global_mut<AllPoolInfos>(@harvest);
        let pool_index = all_pool_infos.total_count;
        table::add(
            &mut all_pool_infos.pool_infos,
            pool_index,
            PoolInfo {
                pool_address: pool_addr,
                stake_coin_name: stake_addr_string,
                reward_coin_name: reward_addr_string
            }
        );
        all_pool_infos.total_count = all_pool_infos.total_count + 1;
    }

    //==============================================================================================
    // Deposit Rewards
    //==============================================================================================

    public fun deposit_reward_coins(
        depositor: &signer, pool_obj: Object<StakePool>, coins: FungibleAsset
    ) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);
        assert!(!is_finished_inner(pool), ERR_HARVEST_FINISHED);

        let amount = fungible_asset::amount(&coins);
        assert!(amount > 0, ERR_AMOUNT_CANNOT_BE_ZERO);

        let additional_duration = amount / pool.reward_per_sec;
        assert!(additional_duration > 0, ERR_DURATION_CANNOT_BE_ZERO);

        pool.end_timestamp = pool.end_timestamp + additional_duration;
        pool.reward_amount = pool.reward_amount + amount;

        primary_fungible_store::deposit(pool_addr, coins);

        event::emit_event<DepositRewardEvent>(
            &mut pool.deposit_events,
            DepositRewardEvent {
                user_address: signer::address_of(depositor),
                amount,
                new_end_timestamp: pool.end_timestamp
            }
        );
    }

    //==============================================================================================
    // Stake
    //==============================================================================================

    public fun stake(
        user: &signer, pool_obj: Object<StakePool>, coins: FungibleAsset
    ) acquires StakePool {
        let amount = fungible_asset::amount(&coins);
        assert!(amount > 0, ERR_AMOUNT_CANNOT_BE_ZERO);

        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
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
                nft_v1: option::none(),
                nft_v2_address: option::none(),
                boosted_amount: 0
            };
            new_stake.unobtainable_reward = (accum_reward * (amount as u128)) / pool.scale;
            table::add(&mut pool.stakes, user_address, new_stake);
        } else {
            let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
            update_user_earnings(accum_reward, pool.scale, user_stake);

            user_stake.amount = user_stake.amount + amount;

            // Recalculate boost if user has NFT
            if (option::is_some(&user_stake.nft_v1)
                || option::is_some(&user_stake.nft_v2_address)) {
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

        pool.stake_amount = pool.stake_amount + amount;
        primary_fungible_store::deposit(pool_addr, coins);

        event::emit_event<StakeEvent>(
            &mut pool.stake_events,
            StakeEvent { user_address, amount }
        );
    }

    //==============================================================================================
    // Unstake
    //==============================================================================================

    public fun unstake(
        user: &signer, pool_obj: Object<StakePool>, amount: u64
    ): FungibleAsset acquires StakePool {
        assert!(amount > 0, ERR_AMOUNT_CANNOT_BE_ZERO);

        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
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

        // Recalculate boost
        if (option::is_some(&user_stake.nft_v1)
            || option::is_some(&user_stake.nft_v2_address)) {
            let boost_percent = option::borrow(&pool.nft_boost_config).boost_percent;
            pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
            user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) /
                100;
            pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;
        };

        user_stake.unobtainable_reward =
            (pool.accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;

        pool.stake_amount = pool.stake_amount - amount;

        event::emit_event<UnstakeEvent>(
            &mut pool.unstake_events,
            UnstakeEvent { user_address, amount }
        );

        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        primary_fungible_store::withdraw(&pool_signer, pool.stake_metadata, amount)
    }

    //==============================================================================================
    // Harvest
    //==============================================================================================

    public fun harvest(user: &signer, pool_obj: Object<StakePool>): FungibleAsset acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
        update_user_earnings(pool.accum_reward, pool.scale, user_stake);

        let earned = user_stake.earned_reward;
        assert!(earned > 0, ERR_NOTHING_TO_HARVEST);

        user_stake.earned_reward = 0;
        pool.reward_amount = pool.reward_amount - earned;

        event::emit_event<HarvestEvent>(
            &mut pool.harvest_events,
            HarvestEvent { user_address, amount: earned }
        );

        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        primary_fungible_store::withdraw(&pool_signer, pool.reward_metadata, earned)
    }

    //==============================================================================================
    // Boost Functions - DUAL NFT STANDARD SUPPORT
    //==============================================================================================

    /// Boost with OLD Token standard (v1)
    /// The Token struct is stored directly in UserStake
    /// Boost with OLD Token standard (v1)
    public fun boost_v1(
        user: &signer, pool_obj: Object<StakePool>, nft: LegacyToken
    ) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);
        assert!(option::is_some(&pool.nft_boost_config), ERR_NON_BOOST_POOL);

        //  FIX: Extract ALL needed values from config FIRST
        let (boost_percent, version, collection_owner, collection_name) = {
            let config = option::borrow(&pool.nft_boost_config);
            (
                config.boost_percent,
                config.version,
                config.collection_identifier,
                config.collection_name
            )
        }; // ← config borrow is DROPPED here!

        // Now validate version
        assert!(version == NFT_VERSION_V1, ERR_WRONG_VERSION);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        // Validate NFT
        let token_amount = token::get_token_amount(&nft);
        assert!(token_amount == 1, ERR_NFT_AMOUNT_MORE_THAN_ONE);

        let token_id = token::get_token_id(&nft);
        let (token_collection_owner, token_collection_name, _, _) =
            token::get_token_id_fields(&token_id);

        assert!(token_collection_owner == collection_owner, ERR_WRONG_TOKEN_COLLECTION);
        assert!(
            *std::string::bytes(&token_collection_name)
                == *std::string::bytes(&collection_name),
            ERR_WRONG_TOKEN_COLLECTION
        );

        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
        update_user_earnings(pool.accum_reward, pool.scale, user_stake);

        // Check not already boosted
        assert!(option::is_none(&user_stake.nft_v1), ERR_ALREADY_BOOSTED);
        assert!(option::is_none(&user_stake.nft_v2_address), ERR_ALREADY_BOOSTED);

        // Store NFT
        option::fill(&mut user_stake.nft_v1, nft);

        // Calculate boost using extracted boost_percent
        user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) / 100;
        pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;

        user_stake.unobtainable_reward =
            (pool.accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;

        event::emit_event(&mut pool.boost_events, BoostEvent { user_address });
    }

    /// Boost with NEW Digital Assets standard (v2)
    /// The NFT object is transferred to the pool and address is stored
    /// Boost with NEW Digital Assets standard (v2)
    public fun boost_v2(
        user: &signer, pool_obj: Object<StakePool>, nft_obj: Object<DigitalAssetToken>
    ) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);
        assert!(option::is_some(&pool.nft_boost_config), ERR_NON_BOOST_POOL);

        //  FIX: Extract ALL needed values from config FIRST
        let (boost_percent, version, collection_identifier) = {
            let config = option::borrow(&pool.nft_boost_config);
            (config.boost_percent, config.version, config.collection_identifier)
        }; // ← config borrow is DROPPED here!

        // Validate version
        assert!(version == NFT_VERSION_V2, ERR_WRONG_VERSION);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        // Verify user owns the NFT
        assert!(object::is_owner(nft_obj, user_address), ERR_NOT_OWNER);

        // Validate collection
        let collection_obj = da_token::collection_object(nft_obj);
        let collection_addr = object::object_address(&collection_obj);
        assert!(collection_addr == collection_identifier, ERR_WRONG_TOKEN_COLLECTION);

        //  NOW we can call update_accum_reward - no active borrows!
        update_accum_reward(pool);

        let nft_addr = object::object_address(&nft_obj);

        //  Use extracted boost_percent
        let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
        update_user_earnings(pool.accum_reward, pool.scale, user_stake);

        // Check not already boosted
        assert!(option::is_none(&user_stake.nft_v1), ERR_ALREADY_BOOSTED);
        assert!(option::is_none(&user_stake.nft_v2_address), ERR_ALREADY_BOOSTED);

        // Transfer NFT to pool
        object::transfer(user, nft_obj, pool_addr);

        // Store NFT address
        option::fill(&mut user_stake.nft_v2_address, nft_addr);

        // Calculate boost using extracted boost_percent
        user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) / 100;
        pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;

        user_stake.unobtainable_reward =
            (pool.accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;

        event::emit_event(&mut pool.boost_events, BoostEvent { user_address });
    }

    /// Remove boost - works for BOTH v1 and v2
    /// Returns: (Option<LegacyToken>, Option<address>)
    /// - For v1: returns the Token, second is none
    /// - For v2: first is none, returns the NFT address (already transferred back to user)
    /// /// Remove NFT boost and return the NFT
    /// Returns: (Option<LegacyToken>, Option<address>)
    ///   - If V1 boost: (Some(token), None)
    ///   - If V2 boost: (None, Some(nft_address)) - NFT is transferred back to user
    public fun remove_boost(
        user: &signer, pool_obj: Object<StakePool>
    ): (Option<LegacyToken>, Option<address>) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        let user_address = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_address), ERR_NO_STAKE);

        // Check which type of boost exists FIRST (before any mutable borrows)
        let has_v1 = {
            let user_stake = table::borrow(&pool.stakes, user_address);
            option::is_some(&user_stake.nft_v1)
        };
        let has_v2 = {
            let user_stake = table::borrow(&pool.stakes, user_address);
            option::is_some(&user_stake.nft_v2_address)
        };

        // Must have at least one type of boost
        assert!(has_v1 || has_v2, ERR_NO_BOOST);

        // Update accumulated rewards
        update_accum_reward(pool);

        // Update user earnings and clear boost
        {
            let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
            update_user_earnings(pool.accum_reward, pool.scale, user_stake);

            // Remove boost from total
            pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
            user_stake.boosted_amount = 0;

            user_stake.unobtainable_reward =
                (pool.accum_reward * user_stake_amount_with_boosted(user_stake))
                    / pool.scale;
        };

        // Emit event
        event::emit_event(
            &mut pool.remove_boost_events, RemoveBoostEvent { user_address }
        );

        //  Handle V1 - extract and return Token
        if (has_v1) {
            let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
            let nft = option::extract(&mut user_stake.nft_v1);
            return (option::some(nft), option::none<address>())
        };

        //  Handle V2 - transfer NFT back to user, return address
        // Extract address first
        let nft_addr = {
            let user_stake = table::borrow_mut(&mut pool.stakes, user_address);
            option::extract(&mut user_stake.nft_v2_address)
        };

        // Transfer NFT back to user
        let nft_obj = object::address_to_object<DigitalAssetToken>(nft_addr);
        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        object::transfer(&pool_signer, nft_obj, user_address);

        (option::none<LegacyToken>(), option::some(nft_addr))
    }

    //==============================================================================
    // Emergency Functions
    //==============================================================================================

    public fun enable_emergency(
        admin: &signer, pool_obj: Object<StakePool>
    ) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        assert!(
            signer::address_of(admin)
                == stake_config_module::get_emergency_admin_address(),
            ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY
        );

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        pool.emergency_locked = true;
    }

    /// Emergency unstake - returns stake coins and any NFT
    public fun emergency_unstake(
        user: &signer, pool_obj: Object<StakePool>
    ): (FungibleAsset, Option<LegacyToken>, Option<address>) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(is_emergency_inner(pool), ERR_NO_EMERGENCY);

        let user_addr = signer::address_of(user);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);

        let user_stake = table::remove(&mut pool.stakes, user_addr);
        let UserStake {
            amount,
            unobtainable_reward: _,
            earned_reward: _,
            unlock_time: _,
            nft_v1,
            nft_v2_address,
            boosted_amount: _
        } = user_stake;

        pool.stake_amount = pool.stake_amount - amount;

        // Handle v2 NFT transfer back if exists
        let nft_v2_result = option::none();
        if (option::is_some(&nft_v2_address)) {
            let nft_addr = option::extract(&mut nft_v2_address);
            let nft_obj = object::address_to_object<DigitalAssetToken>(nft_addr);
            let pool_signer = get_pool_signer_internal(&pool.extend_ref);
            object::transfer(&pool_signer, nft_obj, user_addr);
            nft_v2_result = option::some(nft_addr);
        };
        option::destroy_none(nft_v2_address);

        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        let coins =
            primary_fungible_store::withdraw(&pool_signer, pool.stake_metadata, amount);

        (coins, nft_v1, nft_v2_result)
    }

    public fun withdraw_to_treasury(
        treasury: &signer, pool_obj: Object<StakePool>, amount: u64
    ): FungibleAsset acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        assert!(
            signer::address_of(treasury)
                == stake_config_module::get_treasury_admin_address(),
            ERR_NOT_TREASURY
        );

        let pool = borrow_global_mut<StakePool>(pool_addr);

        if (!is_emergency_inner(pool)) {
            let now = timestamp::now_seconds();
            assert!(
                now >= (pool.end_timestamp + WITHDRAW_REWARD_PERIOD_IN_SECONDS),
                ERR_NOT_WITHDRAW_PERIOD
            );
        };

        pool.reward_amount = pool.reward_amount - amount;

        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        primary_fungible_store::withdraw(&pool_signer, pool.reward_metadata, amount)
    }

    //==============================================================================================
    // View Functions
    //==============================================================================================

    #[view]
    public fun get_pool_total_stake(pool_obj: Object<StakePool>): u64 acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        let pool = borrow_global<StakePool>(pool_addr);
        primary_fungible_store::balance(pool_addr, pool.stake_metadata)
    }

    #[view]
    public fun get_pool_total_reward(pool_obj: Object<StakePool>): u64 acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        let pool = borrow_global<StakePool>(pool_addr);
        primary_fungible_store::balance(pool_addr, pool.reward_metadata)
    }

    #[view]
    public fun pool_exists(pool_obj: Object<StakePool>): bool {
        let pool_addr = object::object_address(&pool_obj);
        exists<StakePool>(pool_addr)
    }

    #[view]
    public fun get_pool_address_view(
        stake_metadata: Object<Metadata>, reward_metadata: Object<Metadata>
    ): address {
        get_pool_address(stake_metadata, reward_metadata)
    }

    #[view]
    public fun address_to_pool_object(pool_addr: address): Object<StakePool> {
        object::address_to_object<StakePool>(pool_addr)
    }

    #[view]
    public fun get_stake_metadata(pool_obj: Object<StakePool>): Object<Metadata> acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        let pool = borrow_global<StakePool>(pool_addr);
        pool.stake_metadata
    }

    #[view]
    public fun get_reward_metadata(pool_obj: Object<StakePool>): Object<Metadata> acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        let pool = borrow_global<StakePool>(pool_addr);
        pool.reward_metadata
    }

    #[view]
    public fun get_pool_info(
        pool_obj: Object<StakePool>
    ): (u64, u128, u64, u64, u128) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        let pool = borrow_global<StakePool>(pool_addr);
        (
            pool.reward_per_sec,
            pool.accum_reward,
            pool.last_updated,
            pool.reward_amount,
            pool.scale
        )
    }

    #[view]
    public fun get_end_timestamp(pool_obj: Object<StakePool>): u64 acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        borrow_global<StakePool>(pool_addr).end_timestamp
    }

    #[view]
    public fun get_user_stake(
        pool_obj: Object<StakePool>, user_addr: address
    ): u64 acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        let pool = borrow_global<StakePool>(pool_addr);
        if (table::contains(&pool.stakes, user_addr)) {
            table::borrow(&pool.stakes, user_addr).amount
        } else { 0 }
    }

    #[view]
    public fun get_unlock_time(
        pool_obj: Object<StakePool>, user_addr: address
    ): u64 acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        let pool = borrow_global<StakePool>(pool_addr);
        assert!(table::contains(&pool.stakes, user_addr), ERR_NO_STAKE);
        table::borrow(&pool.stakes, user_addr).unlock_time
    }

    #[view]
    public fun stake_exists(
        pool_obj: Object<StakePool>, user_addr: address
    ): bool acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        table::contains(&borrow_global<StakePool>(pool_addr).stakes, user_addr)
    }

    #[view]
    public fun get_pool_info_from_registry(
        pool_index: u128
    ): (address, String, String) acquires AllPoolInfos {
        let all_pool_infos = borrow_global<AllPoolInfos>(@harvest);
        assert!(table::contains(&all_pool_infos.pool_infos, pool_index), ERR_NO_POOL);
        let pool_info = table::borrow(&all_pool_infos.pool_infos, pool_index);
        (pool_info.pool_address, pool_info.stake_coin_name, pool_info.reward_coin_name)
    }

    #[view]
    public fun pool_exists_in_registry(pool_index: u128): bool acquires AllPoolInfos {
        table::contains(&borrow_global<AllPoolInfos>(@harvest).pool_infos, pool_index)
    }

    #[view]
    public fun get_total_pools_count(): u128 acquires AllPoolInfos {
        borrow_global<AllPoolInfos>(@harvest).total_count
    }

    #[view]
    public fun get_pool_address_by_index(pool_index: u128): address acquires AllPoolInfos {
        let all_pool_infos = borrow_global<AllPoolInfos>(@harvest);
        assert!(table::contains(&all_pool_infos.pool_infos, pool_index), ERR_NO_POOL);
        table::borrow(&all_pool_infos.pool_infos, pool_index).pool_address
    }

    /// Check if user has boost applied
    #[view]
    public fun user_has_boost(
        pool_obj: Object<StakePool>, user_addr: address
    ): bool acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        let pool = borrow_global<StakePool>(pool_addr);
        if (!table::contains(&pool.stakes, user_addr)) {
            return false
        };
        let user_stake = table::borrow(&pool.stakes, user_addr);
        option::is_some(&user_stake.nft_v1)
            || option::is_some(&user_stake.nft_v2_address)
    }

    /// Get NFT boost config version (1 or 2)
    #[view]
    public fun get_boost_version(pool_obj: Object<StakePool>): u64 acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        let pool = borrow_global<StakePool>(pool_addr);
        if (option::is_none(&pool.nft_boost_config)) {
            return 0 // No boost configured
        };
        option::borrow(&pool.nft_boost_config).version
    }

    //==============================================================================================
    // Private Helper Functions
    //==============================================================================================

    fun is_emergency_inner(pool: &StakePool): bool {
        pool.emergency_locked || stake_config_module::is_global_emergency()
    }

    fun is_finished_inner(pool: &StakePool): bool {
        timestamp::now_seconds() >= pool.end_timestamp
    }

    fun update_accum_reward(pool: &mut StakePool) {
        let current_time = get_time_for_last_update(pool);
        let new_accum_rewards = accum_rewards_since_last_updated(pool, current_time);
        pool.last_updated = current_time;
        if (new_accum_rewards != 0) {
            pool.accum_reward = pool.accum_reward + new_accum_rewards;
        };
    }

    fun accum_rewards_since_last_updated(
        pool: &StakePool, current_time: u64
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

    fun get_time_for_last_update(pool: &StakePool): u64 {
        math64::min(pool.end_timestamp, timestamp::now_seconds())
    }

    fun pool_total_staked_with_boosted(pool: &StakePool): u128 {
        (pool.stake_amount as u128) + pool.total_boosted
    }

    fun user_stake_amount_with_boosted(user_stake: &UserStake): u128 {
        (user_stake.amount as u128) + user_stake.boosted_amount
    }

    //==============================================================================================
    // Event Structs
    //==============================================================================================

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
}

