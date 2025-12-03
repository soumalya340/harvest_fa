/// Collection of entrypoints to handle staking pools (FA Version)
module harvest::scripts {
    use std::option;
    use std::signer;
    use std::string::String;

    // Fungible Asset framework imports replacing the coin module.
    // FA uses Metadata objects for token type identification and primary_fungible_store
    // for user balance management, replacing coin::withdraw/deposit operations.
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::Object;

    use aptos_token::token;

    use harvest::stake;

    /// Registers a new staking pool without NFT boost functionality.
    ///
    /// Changes from Coin standard:
    /// - Added stake_metadata and reward_metadata parameters (Coin standard relied solely on type parameters)
    /// - Uses primary_fungible_store::withdraw instead of coin::withdraw for extracting rewards
    /// - Metadata objects are passed to the core register_pool function for token identification
    ///
    /// Parameters:
    ///     * `pool_owner` - Account which will be used as pool storage
    ///     * `stake_metadata` - Metadata object identifying the stake token type
    ///     * `reward_metadata` - Metadata object identifying the reward token type
    ///     * `reward_amount` - Initial reward amount to deposit
    ///     * `duration` - Pool life duration in seconds, extendable by depositing more rewards
    public entry fun register_pool<S, R>(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64,
        duration: u64
    ) {
        // Withdraw rewards from pool owner's primary fungible store.
        // Coin standard used: coin::withdraw<R>(pool_owner, reward_amount)
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);

        // Pass metadata objects to register_pool for token type identification.
        // Coin standard inferred token types from generic parameters alone.
        stake::register_pool<S, R>(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::none()
        );
    }

    /// Registers a new staking pool with NFT boost functionality.
    ///
    /// Changes from Coin standard:
    /// - Added stake_metadata and reward_metadata parameters for token identification
    /// - Uses primary_fungible_store::withdraw instead of coin::withdraw
    /// - Metadata objects are passed to register_pool for proper FA token handling
    ///
    /// Parameters:
    ///     * `pool_owner` - Account which will be used as pool storage
    ///     * `stake_metadata` - Metadata object identifying the stake token type
    ///     * `reward_metadata` - Metadata object identifying the reward token type
    ///     * `reward_amount` - Initial reward amount to deposit
    ///     * `duration` - Pool life duration in seconds, extendable by depositing more rewards
    ///     * `collection_owner` - Address of NFT collection creator
    ///     * `collection_name` - NFT collection name
    ///     * `boost_percent` - Percentage increase in stake weight when NFT is staked (1-100)
    public entry fun register_pool_with_collection<S, R>(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64,
        duration: u64,
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ) {
        // Withdraw rewards using FA primary store instead of coin::withdraw.
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);

        let boost_config =
            stake::create_boost_config(
                collection_owner,
                collection_name,
                boost_percent
            );

        // Register pool with metadata objects for FA token identification.
        stake::register_pool<S, R>(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::some(boost_config)
        );
    }

    /// Stakes fungible assets into a staking pool.
    ///
    /// Changes from Coin standard:
    /// - Added stake_metadata parameter to identify the token type
    /// - Uses primary_fungible_store::withdraw instead of coin::withdraw
    /// - Withdrawn FungibleAsset is passed to stake function (was Coin<S>)
    ///
    /// Parameters:
    ///     * `user` - Stake owner account
    ///     * `pool_addr` - Address of the pool to stake into
    ///     * `stake_metadata` - Metadata object identifying the stake token type
    ///     * `stake_amount` - Amount of tokens to stake
    public entry fun stake<S, R>(
        user: &signer,
        pool_addr: address,
        stake_metadata: Object<Metadata>,
        stake_amount: u64
    ) {
        // Withdraw from primary fungible store instead of CoinStore<S>.
        let coins = primary_fungible_store::withdraw(user, stake_metadata, stake_amount);
        stake::stake<S, R>(user, pool_addr, coins);
    }

    /// Stakes fungible assets and immediately applies NFT boost in a single transaction.
    ///
    /// Changes from Coin standard:
    /// - Added stake_metadata parameter for FA token identification
    /// - Uses primary_fungible_store::withdraw instead of coin::withdraw for stake tokens
    /// - NFT handling remains unchanged (still uses token standard)
    ///
    /// Parameters:
    ///     * `user` - Stake owner account
    ///     * `pool_addr` - Address of the pool to stake into
    ///     * `stake_metadata` - Metadata object identifying the stake token type
    ///     * `stake_amount` - Amount of tokens to stake
    ///     * `collection_owner` - Address of NFT collection creator
    ///     * `collection_name` - NFT collection name
    ///     * `token_name` - Specific NFT token name
    ///     * `property_version` - Token property version
    public entry fun stake_and_boost<S, R>(
        user: &signer,
        pool_addr: address,
        stake_metadata: Object<Metadata>,
        stake_amount: u64,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64
    ) {
        // Withdraw stake tokens from FA primary store instead of CoinStore.
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

    /// Unstakes fungible assets from a staking pool and returns them to the user.
    ///
    /// Changes from Coin standard:
    /// - Receives FungibleAsset from unstake instead of Coin<S>
    /// - Uses primary_fungible_store::deposit instead of coin::deposit
    /// - No need for coin::register check - FA primary store handles registration automatically
    ///
    /// Parameters:
    ///     * `user` - Stake owner account
    ///     * `pool_addr` - Address of the pool to unstake from
    ///     * `stake_amount` - Amount of tokens to unstake
    public entry fun unstake<S, R>(
        user: &signer, pool_addr: address, stake_amount: u64
    ) {
        let coins = stake::unstake<S, R>(user, pool_addr, stake_amount);
        let user_addr = signer::address_of(user);

        // Deposit to primary fungible store without registration check.
        // Coin standard required: if (!coin::is_account_registered<S>(user_addr)) { coin::register<S>(user) }
        primary_fungible_store::deposit(user_addr, coins);
    }

    /// Unstakes fungible assets and removes NFT boost in a single transaction.
    ///
    /// Changes from Coin standard:
    /// - Receives FungibleAsset from unstake instead of Coin<S>
    /// - Uses primary_fungible_store::deposit instead of coin::deposit
    /// - Eliminates coin registration check (FA handles automatically)
    /// - NFT return handling remains unchanged
    ///
    /// Parameters:
    ///     * `user` - Stake owner account
    ///     * `pool_addr` - Address of the pool to unstake from
    ///     * `stake_amount` - Amount of tokens to unstake
    public entry fun unstake_and_remove_boost<S, R>(
        user: &signer, pool_addr: address, stake_amount: u64
    ) {
        let coins = stake::unstake<S, R>(user, pool_addr, stake_amount);
        let user_addr = signer::address_of(user);

        // Deposit to primary fungible store without manual registration.
        primary_fungible_store::deposit(user_addr, coins);

        let nft = stake::remove_boost<S, R>(user, pool_addr);
        token::deposit_token(user, nft);
    }

    /// Harvests accumulated reward tokens from a staking pool.
    ///
    /// Changes from Coin standard:
    /// - Receives FungibleAsset from harvest instead of Coin<R>
    /// - Uses primary_fungible_store::deposit instead of coin::deposit
    /// - Removed coin::is_account_registered check - no longer needed
    /// - Removed coin::register call - FA primary store auto-registers on first deposit
    ///
    /// Parameters:
    ///     * `user` - Owner of the stake receiving the rewards
    ///     * `pool_addr` - Address of the pool to harvest from
    public entry fun harvest<S, R>(user: &signer, pool_addr: address) {
        let rewards = stake::harvest<S, R>(user, pool_addr);
        let user_addr = signer::address_of(user);

        // Coin standard required manual registration:
        // if (!coin::is_account_registered<R>(user_addr)) { coin::register<R>(user); }
        // FA primary store eliminates this boilerplate.

        // Deposit rewards directly to user's primary fungible store.
        primary_fungible_store::deposit(user_addr, rewards);
    }

    /// Deposits additional reward tokens to extend pool duration.
    ///
    /// Changes from Coin standard:
    /// - Added reward_metadata parameter for token identification
    /// - Uses primary_fungible_store::withdraw instead of coin::withdraw
    /// - Passes FungibleAsset to deposit function instead of Coin<R>
    ///
    /// Parameters:
    ///     * `depositor` - Account with reward tokens to deposit
    ///     * `pool_addr` - Address of the pool to deposit rewards into
    ///     * `reward_metadata` - Metadata object identifying the reward token type
    ///     * `reward_amount` - Amount of reward tokens to deposit
    public entry fun deposit_reward_coins<S, R>(
        depositor: &signer,
        pool_addr: address,
        reward_metadata: Object<Metadata>,
        reward_amount: u64
    ) {
        // Withdraw from primary fungible store instead of CoinStore<R>.
        let reward_coins =
            primary_fungible_store::withdraw(depositor, reward_metadata, reward_amount);
        stake::deposit_reward_coins<S, R>(depositor, pool_addr, reward_coins);
    }

    /// Applies NFT boost to existing stake position.
    ///
    /// No changes from Coin standard:
    /// - NFT handling remains unchanged (uses token standard, not FA)
    /// - Function signature and logic identical to Coin version
    ///
    /// Parameters:
    ///     * `user` - Stake owner account
    ///     * `pool_addr` - Address where pool is stored
    ///     * `collection_owner` - Address of NFT collection creator
    ///     * `collection_name` - NFT collection name
    ///     * `token_name` - Specific NFT token name
    ///     * `property_version` - Token property version
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

    /// Removes NFT boost from stake position and returns the NFT to the user.
    ///
    /// No changes from Coin standard:
    /// - Function logic identical to Coin version
    /// - NFT operations use token standard (unaffected by FA migration)
    ///
    /// Parameters:
    ///     * `user` - Stake owner account
    ///     * `pool_addr` - Address where pool is stored
    public entry fun remove_boost<S, R>(user: &signer, pool_addr: address) {
        let nft = stake::remove_boost<S, R>(user, pool_addr);
        token::deposit_token(user, nft);
    }

    /// Enables emergency state for a pool, restricting normal operations.
    ///
    /// No changes from Coin standard:
    /// - Function logic and signature unchanged
    /// - Emergency state mechanics independent of token standard
    ///
    /// Parameters:
    ///     * `admin` - Current emergency admin account
    ///     * `pool_addr` - Address of the pool to lock
    public entry fun enable_emergency<S, R>(
        admin: &signer, pool_addr: address
    ) {
        stake::enable_emergency<S, R>(admin, pool_addr);
    }

    /// Emergency unstake that bypasses normal restrictions and returns all staked tokens.
    ///
    /// Changes from Coin standard:
    /// - Receives FungibleAsset from emergency_unstake instead of Coin<S>
    /// - Uses primary_fungible_store::deposit instead of coin::deposit
    /// - Removed coin registration check (FA handles automatically)
    /// - NFT handling remains unchanged
    ///
    /// Parameters:
    ///     * `user` - User account with active stake
    ///     * `pool_addr` - Address of the pool to emergency unstake from
    public entry fun emergency_unstake<S, R>(
        user: &signer, pool_addr: address
    ) {
        let (stake_coins, nft) = stake::emergency_unstake<S, R>(user, pool_addr);
        let user_addr = signer::address_of(user);

        // Deposit to primary fungible store without registration boilerplate.
        primary_fungible_store::deposit(user_addr, stake_coins);

        if (option::is_some(&nft)) {
            token::deposit_token(user, option::extract(&mut nft));
        };

        option::destroy_none(nft);
    }

    /// Withdraws unclaimed reward tokens to the treasury account after the withdrawal period.
    ///
    /// Changes from Coin standard:
    /// - Receives FungibleAsset from withdraw_to_treasury instead of Coin<R>
    /// - Uses primary_fungible_store::deposit instead of coin::deposit
    /// - Removed coin::is_account_registered check for treasury account
    /// - Removed coin::register call - FA primary store handles registration
    ///
    /// Parameters:
    ///     * `treasury` - Treasury admin account
    ///     * `pool_addr` - Address of the pool to withdraw from
    ///     * `amount` - Amount of reward tokens to withdraw
    public entry fun withdraw_reward_to_treasury<S, R>(
        treasury: &signer, pool_addr: address, amount: u64
    ) {
        let treasury_addr = signer::address_of(treasury);
        let rewards = stake::withdraw_to_treasury<S, R>(treasury, pool_addr, amount);

        // Coin standard required checking registration and manual registration:
        // if (!coin::is_account_registered<R>(treasury_addr)) { coin::register<R>(treasury); }
        // FA primary store eliminates this complexity.

        // Deposit rewards directly to treasury's primary fungible store.
        primary_fungible_store::deposit(treasury_addr, rewards);
    }
}

