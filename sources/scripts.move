module harvest::scripts {
    use std::option;
    use std::signer;
    use std::string::String;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::Object;
    use aptos_token::token;
    use harvest::stake::{Self, StakePool};

    /// Register pool without boost
    public entry fun register_pool(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64,
        duration: u64
    ) {
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);
        stake::register_pool(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::none()
        );
    }

    /// Register pool with NFT boost
    public entry fun register_pool_with_collection(
        pool_owner: &signer,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_amount: u64,
        duration: u64,
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ) {
        let rewards =
            primary_fungible_store::withdraw(pool_owner, reward_metadata, reward_amount);
        let boost_config =
            stake::create_boost_config(collection_owner, collection_name, boost_percent);
        stake::register_pool(
            pool_owner,
            stake_metadata,
            reward_metadata,
            rewards,
            duration,
            option::some(boost_config)
        );
    }

    /// Stake tokens into pool - metadata auto-fetched from pool
    public entry fun stake(
        user: &signer, pool_obj: Object<StakePool>, stake_amount: u64
    ) {
        // Fetch stake metadata from the pool
        let stake_metadata = stake::get_stake_metadata(pool_obj);
        let coins = primary_fungible_store::withdraw(user, stake_metadata, stake_amount);
        stake::stake(user, pool_obj, coins);
    }

    /// Stake tokens and apply NFT boost - metadata auto-fetched
    public entry fun stake_and_boost(
        user: &signer,
        pool_obj: Object<StakePool>,
        stake_amount: u64,
        collection_owner: address,
        collection_name: String,
        token_name: String,
        property_version: u64
    ) {
        // Fetch stake metadata from the pool
        let stake_metadata = stake::get_stake_metadata(pool_obj);
        let coins = primary_fungible_store::withdraw(user, stake_metadata, stake_amount);
        stake::stake(user, pool_obj, coins);

        let token_id =
            token::create_token_id_raw(
                collection_owner,
                collection_name,
                token_name,
                property_version
            );
        let nft = token::withdraw_token(user, token_id, 1);
        stake::boost(user, pool_obj, nft);
    }

    /// Unstake tokens from pool - no metadata needed!
    public entry fun unstake(
        user: &signer, pool_obj: Object<StakePool>, stake_amount: u64
    ) {
        let coins = stake::unstake(user, pool_obj, stake_amount);
        let user_addr = signer::address_of(user);
        primary_fungible_store::deposit(user_addr, coins);
    }

    /// Unstake tokens and remove NFT boost
    public entry fun unstake_and_remove_boost(
        user: &signer, pool_obj: Object<StakePool>, stake_amount: u64
    ) {
        let coins = stake::unstake(user, pool_obj, stake_amount);
        let user_addr = signer::address_of(user);
        primary_fungible_store::deposit(user_addr, coins);

        let nft = stake::remove_boost(user, pool_obj);
        token::deposit_token(user, nft);
    }

    /// Harvest accumulated rewards
    public entry fun harvest(user: &signer, pool_obj: Object<StakePool>) {
        let rewards = stake::harvest(user, pool_obj);
        let user_addr = signer::address_of(user);
        primary_fungible_store::deposit(user_addr, rewards);
    }

    /// Deposit additional rewards to extend pool duration
    public entry fun deposit_reward_coins(
        depositor: &signer, pool_obj: Object<StakePool>, reward_amount: u64
    ) {
        // Fetch reward metadata from the pool
        let reward_metadata = stake::get_reward_metadata(pool_obj);
        let reward_coins =
            primary_fungible_store::withdraw(depositor, reward_metadata, reward_amount);
        stake::deposit_reward_coins(depositor, pool_obj, reward_coins);
    }

    /// Apply NFT boost to existing stake
    public entry fun boost(
        user: &signer,
        pool_obj: Object<StakePool>,
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
        stake::boost(user, pool_obj, nft);
    }

    /// Remove NFT boost and return NFT
    public entry fun remove_boost(
        user: &signer, pool_obj: Object<StakePool>
    ) {
        let nft = stake::remove_boost(user, pool_obj);
        token::deposit_token(user, nft);
    }

    /// Enable emergency mode for pool
    public entry fun enable_emergency(
        admin: &signer, pool_obj: Object<StakePool>
    ) {
        stake::enable_emergency(admin, pool_obj);
    }

    /// Emergency unstake bypassing restrictions
    public entry fun emergency_unstake(
        user: &signer, pool_obj: Object<StakePool>
    ) {
        let (stake_coins, nft) = stake::emergency_unstake(user, pool_obj);
        let user_addr = signer::address_of(user);
        primary_fungible_store::deposit(user_addr, stake_coins);

        if (option::is_some(&nft)) {
            token::deposit_token(user, option::extract(&mut nft));
        };
        option::destroy_none(nft);
    }

    /// Withdraw unclaimed rewards to treasury
    public entry fun withdraw_reward_to_treasury(
        treasury: &signer, pool_obj: Object<StakePool>, amount: u64
    ) {
        let treasury_addr = signer::address_of(treasury);
        let rewards = stake::withdraw_to_treasury(treasury, pool_obj, amount);
        primary_fungible_store::deposit(treasury_addr, rewards);
    }
}

