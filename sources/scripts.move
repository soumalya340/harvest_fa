/// Collection of entrypoints to handle staking pools (FA Version)
module harvest::scripts {
    use std::option;
    use std::signer;
    use std::string::String;

    // ⭐ NEW: FA imports instead of coin
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::Object;

    use aptos_token::token;

    use harvest::stake;

    /// ⭐ CHANGED: Register new staking pool without nft boost (FA version)
    /// Now requires metadata objects to identify stake and reward tokens
    ///     * `pool_owner` - account which will be used as a pool storage.
    ///     * `stake_metadata` - metadata object of the stake token.
    ///     * `reward_metadata` - metadata object of the reward token.
    ///     * `reward_amount` - reward amount in R tokens.
    ///     * `duration` - pool life duration, can be increased by depositing more rewards.
    public entry fun register_pool<S, R>(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>, // ⭐ NEW parameter
        reward_metadata: Object<Metadata>, // ⭐ NEW parameter
        reward_amount: u64,
        duration: u64
    ) {
        // ⭐ CHANGED: Use primary_fungible_store::withdraw instead of coin::withdraw
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);

        // ⭐ CHANGED: Pass metadata objects to register_pool
        stake::register_pool<S, R>(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::none()
        );
    }

    /// ⭐ CHANGED: Register new staking pool with nft boost (FA version)
    ///     * `pool_owner` - account which will be used as a pool storage.
    ///     * `stake_metadata` - metadata object of the stake token.
    ///     * `reward_metadata` - metadata object of the reward token.
    ///     * `reward_amount` - reward amount in R tokens.
    ///     * `duration` - pool life duration, can be increased by depositing more rewards.
    ///     * `collection_owner` - address of nft collection creator.
    ///     * `collection_name` - nft collection name.
    ///     * `boost_percent` - percentage of increasing user stake "power" after nft stake.
    public entry fun register_pool_with_collection<S, R>(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>, // ⭐ NEW parameter
        reward_metadata: Object<Metadata>, // ⭐ NEW parameter
        reward_amount: u64,
        duration: u64,
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ) {
        // ⭐ CHANGED: Use primary_fungible_store::withdraw
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);

        let boost_config =
            stake::create_boost_config(
                collection_owner,
                collection_name,
                boost_percent
            );

        // ⭐ CHANGED: Pass metadata objects to register_pool
        stake::register_pool<S, R>(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::some(boost_config)
        );
    }

    /// ⭐ CHANGED: Stake tokens to pool (FA version)
    ///     * `user` - stake owner.
    ///     * `pool_addr` - address of the pool to stake.
    ///     * `stake_metadata` - metadata object of the stake token.
    ///     * `stake_amount` - amount of tokens to stake.
    public entry fun stake<S, R>(
        user: &signer,
        pool_addr: address,
        stake_metadata: Object<Metadata>, // ⭐ NEW parameter
        stake_amount: u64
    ) {
        // ⭐ CHANGED: Use primary_fungible_store::withdraw
        let coins = primary_fungible_store::withdraw(user, stake_metadata, stake_amount);
        stake::stake<S, R>(user, pool_addr, coins);
    }

    /// ⭐ CHANGED: Stake tokens and boost with NFT (FA version)
    ///     * `user` - stake owner.
    ///     * `pool_addr` - address of the pool to stake.
    ///     * `stake_metadata` - metadata object of the stake token.
    ///     * `stake_amount` - amount of tokens to stake.
    ///     * `collection_owner` - address of nft collection creator.
    ///     * `collection_name` - nft collection name.
    ///     * `token_name` - token name.
    ///     * `property_version` - token property version.
    public entry fun stake_and_boost<S, R>(
        user: &signer,
        pool_addr: address,
        stake_metadata: Object<Metadata>, // ⭐ NEW parameter
        stake_amount: u64,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64
    ) {
        // ⭐ CHANGED: Use primary_fungible_store::withdraw
        let coins = primary_fungible_store::withdraw(user, stake_metadata, stake_amount);
        stake::stake<S, R>(user, pool_addr, coins);

        let token_id =
            token::create_token_id_raw(
                collection_owner,
                collection_name,
                token_name,
                property_version
            );
        let nft = token::withdraw_token(user, token_id, 1);

        stake::boost<S, R>(user, pool_addr, nft);
    }

    /// ⭐ CHANGED: Unstake tokens from pool (FA version)
    ///     * `user` - stake owner.
    ///     * `pool_addr` - address of the pool to unstake.
    ///     * `stake_amount` - amount of tokens to unstake.
    public entry fun unstake<S, R>(
        user: &signer, pool_addr: address, stake_amount: u64
    ) {
        let coins = stake::unstake<S, R>(user, pool_addr, stake_amount);
        let user_addr = signer::address_of(user);

        // ⭐ CHANGED: Use primary_fungible_store::deposit
        // Note: No need to check registration - FA handles it automatically!
        primary_fungible_store::deposit(user_addr, coins);
    }

    /// ⭐ CHANGED: Unstake and remove boost (FA version)
    ///     * `user` - stake owner.
    ///     * `pool_addr` - address of the pool to unstake.
    ///     * `stake_amount` - amount of tokens to unstake.
    public entry fun unstake_and_remove_boost<S, R>(
        user: &signer, pool_addr: address, stake_amount: u64
    ) {
        let coins = stake::unstake<S, R>(user, pool_addr, stake_amount);
        let user_addr = signer::address_of(user);

        // ⭐ CHANGED: Use primary_fungible_store::deposit (no registration needed!)
        primary_fungible_store::deposit(user_addr, coins);

        let nft = stake::remove_boost<S, R>(user, pool_addr);
        token::deposit_token(user, nft);
    }

    /// ⭐ CHANGED: Harvest rewards (FA version)
    ///     * `user` - owner of the stake used to receive the rewards.
    ///     * `pool_addr` - address of the pool.
    public entry fun harvest<S, R>(user: &signer, pool_addr: address) {
        let rewards = stake::harvest<S, R>(user, pool_addr);
        let user_addr = signer::address_of(user);

        // ⭐ REMOVED: No need for coin::is_account_registered check!
        // ⭐ REMOVED: No need for coin::register!
        // FA automatically handles registration on first deposit

        // ⭐ CHANGED: Use primary_fungible_store::deposit
        primary_fungible_store::deposit(user_addr, rewards);
    }

    /// ⭐ CHANGED: Deposit more rewards to pool (FA version)
    ///     * `depositor` - account with the reward tokens in the balance.
    ///     * `pool_addr` - address of the pool.
    ///     * `reward_metadata` - metadata object of the reward token.
    ///     * `reward_amount` - amount of the reward tokens to deposit.
    public entry fun deposit_reward_coins<S, R>(
        depositor: &signer,
        pool_addr: address,
        reward_metadata: Object<Metadata>, // ⭐ NEW parameter
        reward_amount: u64
    ) {
        // ⭐ CHANGED: Use primary_fungible_store::withdraw
        let reward_coins =
            primary_fungible_store::withdraw(depositor, reward_metadata, reward_amount);
        stake::deposit_reward_coins<S, R>(depositor, pool_addr, reward_coins);
    }

    /// Boosts user stake with nft (unchanged - NFTs still use token standard)
    ///     * `user` - stake owner account.
    ///     * `pool_addr` - address under which pool are stored.
    ///     * `collection_owner` - address of nft collection creator.
    ///     * `collection_name` - nft collection name.
    ///     * `token_name` - token name.
    ///     * `property_version` - token property version.
    public entry fun boost<S, R>(
        user: &signer,
        pool_addr: address,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64
    ) {
        let token_id =
            token::create_token_id_raw(
                collection_owner,
                collection_name,
                token_name,
                property_version
            );

        let nft = token::withdraw_token(user, token_id, 1);
        stake::boost<S, R>(user, pool_addr, nft);
    }

    /// Removes nft boost (unchanged)
    ///     * `user` - stake owner account.
    ///     * `pool_addr` - address under which pool are stored.
    public entry fun remove_boost<S, R>(user: &signer, pool_addr: address) {
        let nft = stake::remove_boost<S, R>(user, pool_addr);
        token::deposit_token(user, nft);
    }

    /// Enable emergency state (unchanged)
    ///     * `admin` - current emergency admin account.
    ///     * `pool_addr` - address of the the pool.
    public entry fun enable_emergency<S, R>(
        admin: &signer, pool_addr: address
    ) {
        stake::enable_emergency<S, R>(admin, pool_addr);
    }

    /// ⭐ CHANGED: Emergency unstake (FA version)
    ///     * `user` - user account which has stake.
    ///     * `pool_addr` - address of the pool.
    public entry fun emergency_unstake<S, R>(
        user: &signer, pool_addr: address
    ) {
        let (stake_coins, nft) = stake::emergency_unstake<S, R>(user, pool_addr);
        let user_addr = signer::address_of(user);

        // ⭐ CHANGED: Use primary_fungible_store::deposit (no registration needed!)
        primary_fungible_store::deposit(user_addr, stake_coins);

        if (option::is_some(&nft)) {
            token::deposit_token(user, option::extract(&mut nft));
        };

        option::destroy_none(nft);
    }

    /// ⭐ CHANGED: Withdraw rewards to treasury (FA version)
    ///     * `treasury` - treasury account.
    ///     * `pool_addr` - pool address.
    ///     * `amount` - amount to withdraw.
    public entry fun withdraw_reward_to_treasury<S, R>(
        treasury: &signer, pool_addr: address, amount: u64
    ) {
        let treasury_addr = signer::address_of(treasury);
        let rewards = stake::withdraw_to_treasury<S, R>(treasury, pool_addr, amount);

        // ⭐ REMOVED: No need for coin::is_account_registered check!
        // ⭐ REMOVED: No need for coin::register!

        // ⭐ CHANGED: Use primary_fungible_store::deposit
        primary_fungible_store::deposit(treasury_addr, rewards);
    }
}

