module harvest::stake {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::math64;
    use aptos_std::math128;
    use aptos_std::table;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::timestamp;
    use aptos_token::token::{Self, Token};
    use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, Object, ExtendRef};

    use harvest::stake_config;

    //==============================================================================================
    // Error codes
    //==============================================================================================

    /// Pool does not exist at the specified address
    const ERR_NO_POOL: u64 = 100;
    /// Pool already exists for this stake and reward token pair
    const ERR_POOL_ALREADY_EXISTS: u64 = 101;
    /// Reward per second cannot be zero (reward amount / duration must be > 0)
    const ERR_REWARD_CANNOT_BE_ZERO: u64 = 102;
    /// User has no stake in this pool
    const ERR_NO_STAKE: u64 = 103;
    /// User does not have enough staked balance for this operation
    const ERR_NOT_ENOUGH_S_BALANCE: u64 = 104;
    /// Amount must be greater than zero
    const ERR_AMOUNT_CANNOT_BE_ZERO: u64 = 105;
    /// No rewards available to harvest
    const ERR_NOTHING_TO_HARVEST: u64 = 106;
    /// Cannot unstake before unlock time (1 week lock period)
    const ERR_TOO_EARLY_UNSTAKE: u64 = 108;
    /// Pool is in emergency mode, normal operations are disabled
    const ERR_EMERGENCY: u64 = 109;
    /// Pool is not in emergency mode, cannot perform emergency operations
    const ERR_NO_EMERGENCY: u64 = 110;
    /// Caller does not have permission to enable emergency mode
    const ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY: u64 = 111;
    /// Duration must be greater than zero
    const ERR_DURATION_CANNOT_BE_ZERO: u64 = 112;
    /// Harvest period has ended, cannot stake or add rewards
    const ERR_HARVEST_FINISHED: u64 = 113;
    /// Cannot withdraw rewards yet, must wait for withdrawal period
    const ERR_NOT_WITHDRAW_PERIOD: u64 = 114;
    /// Caller is not the treasury admin
    const ERR_NOT_TREASURY: u64 = 115;
    /// NFT collection is not configured
    const ERR_NO_COLLECTION: u64 = 116;
    /// Boost percent is invalid (must be between 1 and 100)
    const ERR_INVALID_BOOST_PERCENT: u64 = 117;
    /// Pool does not have NFT boost enabled
    const ERR_NON_BOOST_POOL: u64 = 118;
    /// User already has an NFT boost applied
    const ERR_ALREADY_BOOSTED: u64 = 119;
    /// NFT collection does not match the pool's configured collection
    const ERR_WRONG_TOKEN_COLLECTION: u64 = 120;
    /// User does not have an NFT boost to remove
    const ERR_NO_BOOST: u64 = 121;
    /// NFT amount must be exactly 1
    const ERR_NFT_AMOUNT_MORE_THAN_ONE: u64 = 122;
    /// Reward token decimals must be 10 or less for calculation safety
    const ERR_INVALID_REWARD_DECIMALS: u64 = 123;

    //==============================================================================================
    // Constants
    //==============================================================================================

    const WEEK_IN_SECONDS: u64 = 604800;
    const WITHDRAW_REWARD_PERIOD_IN_SECONDS: u64 = 7257600;
    const MIN_NFT_BOOST_PRECENT: u128 = 1;
    const MAX_NFT_BOOST_PERCENT: u128 = 100;
    const ACCUM_REWARD_SCALE: u128 = 1000000000000;

    /// Resource account seed - this makes your resource account address deterministic
    const RESOURCE_ACCOUNT_SEED: vector<u8> = b"harvest_stake_v1";

    //==============================================================================================
    // Structs
    //==============================================================================================

    /// Stores a signing capability for the Resource Account
    /// This is stored at the module's address (@harvest)
    struct SignerCapabilityStore has key {
        signer_capability: SignerCapability
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct StakePool has key {
        pool_creator: address, // Address of who created the pool (for tracking)
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,

        // Pool parameters
        reward_per_sec: u64,
        accum_reward: u128,
        last_updated: u64,
        start_timestamp: u64,
        end_timestamp: u64,

        // User stakes tracking
        stakes: table::Table<address, UserStake>,
        stake_amount: u64, // Total staked in this pool
        reward_amount: u64, // Total rewards in this pool
        extend_ref: ExtendRef,
        scale: u128,
        total_boosted: u128,
        nft_boost_config: Option<NFTBoostConfig>,
        emergency_locked: bool,

        // Events
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

    //==============================================================================================
    // Initialize Module - Creates Resource Account ONCE
    //==============================================================================================

    /// This runs ONCE when you deploy the module
    /// It creates the resource account that will own all pools
    fun init_module(deployer: &signer) {
        // Create resource account using deterministic seed
        let (_, signer_capability) =
            account::create_resource_account(deployer, RESOURCE_ACCOUNT_SEED);

        // Store the signer capability at YOUR MODULE ADDRESS (@harvest)
        move_to(deployer, SignerCapabilityStore { signer_capability });
    }

    //==============================================================================================
    // Helper Functions - Resource Account Management
    //==============================================================================================

    /// Get the resource account's address
    /// This address will own all pool objects!
    #[view]
    public fun get_resource_account_address(): address acquires SignerCapabilityStore {
        let signer_cap_store = borrow_global<SignerCapabilityStore>(@harvest);
        account::get_signer_capability_address(&signer_cap_store.signer_capability)
    }

    /// Get the resource account's signer
    /// Use this when you need the resource account to sign transactions
    fun get_resource_account_signer(): signer acquires SignerCapabilityStore {
        let signer_cap_store = borrow_global<SignerCapabilityStore>(@harvest);
        account::create_signer_with_capability(&signer_cap_store.signer_capability)
    }

    //==============================================================================================
    // Helper Functions - Get Pool Object
    //==============================================================================================

    /// Creates a unique pool address based on resource account and token metadata.
    /// Each combination of stake and reward tokens gets a unique pool address.
    fun get_pool_address(
        stake_metadata: Object<Metadata>, reward_metadata: Object<Metadata>
    ): address acquires SignerCapabilityStore {
        let resource_account_addr = get_resource_account_address();

        // Get token names for unique identification
        let stake_name = fungible_asset::name(stake_metadata);
        let reward_name = fungible_asset::name(reward_metadata);

        // Combine into unique seed: "StakePool::<stake_name>::<reward_name>"
        let seed = b"StakePool::";
        std::vector::append(&mut seed, *std::string::bytes(&stake_name));
        std::vector::append(&mut seed, b"::");
        std::vector::append(&mut seed, *std::string::bytes(&reward_name));

        object::create_object_address(&resource_account_addr, seed)
    }

    /// Get pool object signer using ExtendRef
    fun get_pool_signer(pool_addr: address): signer acquires StakePool {
        let pool = borrow_global<StakePool>(pool_addr);
        object::generate_signer_for_extending(&pool.extend_ref)
    }

    /// Internal version that takes ExtendRef directly
    fun get_pool_signer_internal(extend_ref: &ExtendRef): signer {
        object::generate_signer_for_extending(extend_ref)
    }

    //==============================================================================================
    // Pool Creation
    //==============================================================================================

    /// Create NFT boost configuration
    public fun create_boost_config(
        collection_owner: address, collection_name: String, boost_percent: u128
    ): NFTBoostConfig {
        assert!(
            boost_percent >= MIN_NFT_BOOST_PRECENT
                && boost_percent <= MAX_NFT_BOOST_PERCENT,
            ERR_INVALID_BOOST_PERCENT
        );
        NFTBoostConfig { boost_percent, collection_owner, collection_name }
    }

    /// Register a new staking pool
    /// All pools are created under the resource account
    public fun register_pool(
        owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_coins: FungibleAsset,
        duration: u64,
        nft_boost_config: Option<NFTBoostConfig>
    ) acquires SignerCapabilityStore {
        let owner_addr = signer::address_of(owner);

        // Get pool address (under resource account)
        let pool_addr = get_pool_address(stake_metadata, reward_metadata);

        // Check pool doesn't exist
        assert!(!exists<StakePool>(pool_addr), ERR_POOL_ALREADY_EXISTS);
        assert!(duration > 0, ERR_DURATION_CANNOT_BE_ZERO);

        // Calculate reward rate
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

        // Create unique seed matching get_pool_address logic
        let seed = b"StakePool::";
        let stake_name = fungible_asset::name(stake_metadata);
        let reward_name = fungible_asset::name(reward_metadata);
        std::vector::append(&mut seed, *std::string::bytes(&stake_name));
        std::vector::append(&mut seed, b"::");
        std::vector::append(&mut seed, *std::string::bytes(&reward_name));

        // KEY CHANGE: Use RESOURCE ACCOUNT to create pool object!
        let resource_account_signer = get_resource_account_signer();
        let constructor_ref = object::create_named_object(
            &resource_account_signer, seed
        );

        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        // Deposit rewards to pool object's primary store
        primary_fungible_store::deposit(pool_addr, reward_coins);

        let pool = StakePool {
            pool_creator: owner_addr, // Track who created it
            stake_metadata,
            reward_metadata,
            reward_per_sec,
            accum_reward: 0,
            last_updated: current_time,
            start_timestamp: current_time,
            end_timestamp,
            stakes: table::new(),

            // Track amounts instead of store addresses
            stake_amount: 0,
            reward_amount,

            // Store ExtendRef for signing later
            extend_ref,
            scale,
            total_boosted: 0,
            nft_boost_config,
            emergency_locked: false,

            // Events
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

        // Deposit rewards to pool object's primary store
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
    // Stake - User Deposits Tokens
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

        // Update tracked amount
        pool.stake_amount = pool.stake_amount + amount;

        // Deposit to pool object's primary store
        primary_fungible_store::deposit(pool_addr, coins);

        event::emit_event<StakeEvent>(
            &mut pool.stake_events,
            StakeEvent { user_address, amount }
        );
    }

    //==============================================================================================
    // Unstake - Withdraw Tokens
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

        if (option::is_some(&user_stake.nft)) {
            let boost_percent = option::borrow(&pool.nft_boost_config).boost_percent;
            pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
            user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) /
                100;
            pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;
        };

        user_stake.unobtainable_reward =
            (pool.accum_reward * user_stake_amount_with_boosted(user_stake)) / pool.scale;

        // Update tracked amount
        pool.stake_amount = pool.stake_amount - amount;

        event::emit_event<UnstakeEvent>(
            &mut pool.unstake_events,
            UnstakeEvent { user_address, amount }
        );

        // Pool object signs and transfers tokens!
        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        primary_fungible_store::withdraw(&pool_signer, pool.stake_metadata, amount)
    }

    //==============================================================================================
    // Harvest - Claim Rewards
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

        // Update tracked amount
        pool.reward_amount = pool.reward_amount - earned;

        event::emit_event<HarvestEvent>(
            &mut pool.harvest_events,
            HarvestEvent { user_address, amount: earned }
        );

        // Pool object signs and transfers rewards!
        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        primary_fungible_store::withdraw(&pool_signer, pool.reward_metadata, earned)
    }

    //==============================================================================================
    // Boost Functions
    //==============================================================================================

    public fun boost(
        user: &signer, pool_obj: Object<StakePool>, nft: Token
    ) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
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
        assert!(
            std::string::bytes(&token_collection_name)
                == std::string::bytes(&collection_name),
            ERR_WRONG_TOKEN_COLLECTION
        );

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

    public fun remove_boost(user: &signer, pool_obj: Object<StakePool>): Token acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);

        let pool = borrow_global_mut<StakePool>(pool_addr);
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

    //==============================================================================================
    // Emergency Functions
    //==============================================================================================

    public fun enable_emergency(
        admin: &signer, pool_obj: Object<StakePool>
    ) acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        assert!(
            signer::address_of(admin) == stake_config::get_emergency_admin_address(),
            ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY
        );

        let pool = borrow_global_mut<StakePool>(pool_addr);
        assert!(!is_emergency_inner(pool), ERR_EMERGENCY);

        pool.emergency_locked = true;
    }

    public fun emergency_unstake(
        user: &signer, pool_obj: Object<StakePool>
    ): (FungibleAsset, Option<Token>) acquires StakePool {
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
            nft,
            boosted_amount: _
        } = user_stake;

        // Update tracked amount
        pool.stake_amount = pool.stake_amount - amount;

        // Pool object signs withdrawal
        let pool_signer = get_pool_signer_internal(&pool.extend_ref);
        let coins =
            primary_fungible_store::withdraw(&pool_signer, pool.stake_metadata, amount);

        (coins, nft)
    }

    public fun withdraw_to_treasury(
        treasury: &signer, pool_obj: Object<StakePool>, amount: u64
    ): FungibleAsset acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        assert!(exists<StakePool>(pool_addr), ERR_NO_POOL);
        assert!(
            signer::address_of(treasury) == stake_config::get_treasury_admin_address(),
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
    /// Returns the pool object address from token metadata
    /// Now uses resource account instead of pool_creator!
    public fun get_pool_address_view(
        stake_metadata: Object<Metadata>, reward_metadata: Object<Metadata>
    ): address acquires SignerCapabilityStore {
        get_pool_address(stake_metadata, reward_metadata)
    }

    #[view]
    /// Converts pool address to pool object
    public fun address_to_pool_object(pool_addr: address): Object<StakePool> {
        object::address_to_object<StakePool>(pool_addr)
    }

    #[view]
    /// Get stake metadata from pool
    public fun get_stake_metadata(pool_obj: Object<StakePool>): Object<Metadata> acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        let pool = borrow_global<StakePool>(pool_addr);
        pool.stake_metadata
    }

    #[view]
    /// Get reward metadata from pool
    public fun get_reward_metadata(pool_obj: Object<StakePool>): Object<Metadata> acquires StakePool {
        let pool_addr = object::object_address(&pool_obj);
        let pool = borrow_global<StakePool>(pool_addr);
        pool.reward_metadata
    }

    //==============================================================================================
    // Private Helper Functions
    //==============================================================================================

    fun is_emergency_inner(pool: &StakePool): bool {
        pool.emergency_locked || stake_config::is_global_emergency()
    }

    fun is_finished_inner(pool: &StakePool): bool {
        let now = timestamp::now_seconds();
        now >= pool.end_timestamp
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

