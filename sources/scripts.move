module harvest::scripts {
    use std::option;
    use std::signer;
    use std::string::String;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::Object;

    // OLD NFT Standard (v1)
    use aptos_token::token;

    // NEW NFT Standard (v2) - Digital Assets
    use aptos_token_objects::token::Token as DigitalAssetToken;

    use harvest::stake::{Self as stake_module, StakePool};

    //==============================================================================================
    // Pool Registration
    //==============================================================================================

    /// Register pool without NFT boost
    public entry fun register_pool(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64,
        duration: u64
    ) {
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);
        stake_module::register_pool(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::none()
        );
    }

    /// Register pool with NFT boost support
    /// version: 1 = old Token standard, 2 = new Digital Assets standard
    /// collection_identifier:
    ///   - For v1: the collection creator's address
    ///   - For v2: the collection object's address
    public entry fun register_pool_with_boost(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64,
        duration: u64,
        version: u64,
        collection_identifier: address,
        collection_name: String,
        boost_percent: u128
    ) {
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);
        let boost_config =
            stake_module::create_boost_config(
                version,
                collection_identifier,
                collection_name,
                boost_percent
            );
        stake_module::register_pool(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::some(boost_config)
        );
    }

    //==============================================================================================
    // Staking Functions
    //==============================================================================================

    /// Stake tokens into pool
    public entry fun stake(
        user: &signer, pool_obj: Object<StakePool>, stake_amount: u64
    ) {
        let stake_metadata = stake_module::get_stake_metadata(pool_obj);
        let coins = primary_fungible_store::withdraw(user, stake_metadata, stake_amount);
        stake_module::stake(user, pool_obj, coins);
    }

    /// Unstake tokens from pool
    public entry fun unstake(
        user: &signer, pool_obj: Object<StakePool>, stake_amount: u64
    ) {
        let coins = stake_module::unstake(user, pool_obj, stake_amount);
        let user_addr = signer::address_of(user);
        primary_fungible_store::deposit(user_addr, coins);
    }

    /// Harvest accumulated rewards
    public entry fun harvest(user: &signer, pool_obj: Object<StakePool>) {
        let rewards = stake_module::harvest(user, pool_obj);
        let user_addr = signer::address_of(user);
        primary_fungible_store::deposit(user_addr, rewards);
    }

    /// Deposit additional rewards to extend pool duration
    public entry fun deposit_reward_coins(
        depositor: &signer, pool_obj: Object<StakePool>, reward_amount: u64
    ) {
        let reward_metadata = stake_module::get_reward_metadata(pool_obj);
        let reward_coins =
            primary_fungible_store::withdraw(depositor, reward_metadata, reward_amount);
        stake_module::deposit_reward_coins(depositor, pool_obj, reward_coins);
    }

    //==============================================================================================
    // Boost Functions - V1 (Old Token Standard)
    //==============================================================================================

    /// Apply NFT boost using OLD Token standard (v1)
    /// Requires: collection_owner, collection_name, token_name, property_version
    public entry fun boost_v1(
        user: &signer,
        pool_obj: Object<StakePool>,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64
    ) {
        // Create token ID for old standard
        let token_id =
            token::create_token_id_raw(
                collection_owner,
                collection_name,
                token_name,
                property_version
            );

        // Withdraw the NFT from user's token store
        let nft = token::withdraw_token(user, token_id, 1);

        // Apply boost
        stake_module::boost_v1(user, pool_obj, nft);
    }

    //==============================================================================================
    // Boost Functions - V2 (New Digital Assets Standard)
    //==============================================================================================

    /// Apply NFT boost using NEW Digital Assets standard (v2)
    /// User passes the NFT object directly
    public entry fun boost_v2(
        user: &signer, pool_obj: Object<StakePool>, nft_obj: Object<DigitalAssetToken>
    ) {
        stake_module::boost_v2(user, pool_obj, nft_obj);
    }

    //==============================================================================================
    // Remove Boost - Works for BOTH standards!
    //==============================================================================================

    /// Remove NFT boost (works for both v1 and v2)
    /// - For v1: NFT is returned to user's token store
    /// - For v2: NFT is already transferred back to user in the stake module
    public entry fun remove_boost(
        user: &signer, pool_obj: Object<StakePool>
    ) {
        let (nft_v1, _nft_v2_addr) = stake_module::remove_boost(user, pool_obj);

        // For v1: deposit the Token back to user's token store
        if (option::is_some(&nft_v1)) {
            token::deposit_token(user, option::extract(&mut nft_v1));
        };
        option::destroy_none(nft_v1);

        // For v2: NFT was already transferred back to user in stake::remove_boost
        // The address is returned just for reference/events, we don't need to do anything
    }

    //==============================================================================================
    // Emergency Functions
    //==============================================================================================

    /// Enable emergency mode for pool (admin only)
    public entry fun enable_emergency(
        admin: &signer, pool_obj: Object<StakePool>
    ) {
        stake_module::enable_emergency(admin, pool_obj);
    }

    /// Emergency unstake - bypasses lock period
    /// Returns all staked tokens and any NFT boost
    public entry fun emergency_unstake(
        user: &signer, pool_obj: Object<StakePool>
    ) {
        let (stake_coins, nft_v1, _nft_v2_addr) =
            stake_module::emergency_unstake(user, pool_obj);
        let user_addr = signer::address_of(user);

        // Deposit staked tokens back
        primary_fungible_store::deposit(user_addr, stake_coins);

        // For v1: deposit NFT back to token store
        if (option::is_some(&nft_v1)) {
            token::deposit_token(user, option::extract(&mut nft_v1));
        };
        option::destroy_none(nft_v1);

        // For v2: NFT was already transferred back in stake_module::emergency_unstake
    }

    /// Withdraw unclaimed rewards to treasury (treasury admin only)
    public entry fun withdraw_reward_to_treasury(
        treasury: &signer, pool_obj: Object<StakePool>, amount: u64
    ) {
        let treasury_addr = signer::address_of(treasury);
        let rewards = stake_module::withdraw_to_treasury(treasury, pool_obj, amount);
        primary_fungible_store::deposit(treasury_addr, rewards);
    }
}

