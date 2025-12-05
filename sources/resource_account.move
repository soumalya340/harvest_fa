module harvest::resource_account {
    use aptos_framework::account::{Self, SignerCapability};

    /// Resource account seed - this makes your resource account address deterministic
    const RESOURCE_ACCOUNT_SEED: vector<u8> = b"harvest_stake_v1";

    /// Stores a signing capability for the Resource Account
    /// This is stored at the module's address (@harvest)
    struct SignerCapabilityStore has key {
        signer_capability: SignerCapability
    }

    /// This runs ONCE when you deploy the module
    /// It creates the resource account that will own all pools
    fun init_module(deployer: &signer) {
        // Create resource account using deterministic seed
        let (_, signer_capability) =
            account::create_resource_account(deployer, RESOURCE_ACCOUNT_SEED);

        // Store the signer capability at YOUR MODULE ADDRESS (@harvest)
        move_to(deployer, SignerCapabilityStore { signer_capability });
    }

    /// Get the resource account's address
    /// This address will own all pool objects!
    #[view]
    public fun get_resource_account_address(): address acquires SignerCapabilityStore {
        let signer_cap_store = borrow_global<SignerCapabilityStore>(@harvest);
        account::get_signer_capability_address(&signer_cap_store.signer_capability)
    }

    /// Get the resource account's signer
    /// Use this when you need the resource account to sign transactions
    #[view]
    public fun get_resource_account_signer(): signer acquires SignerCapabilityStore {
        let signer_cap_store = borrow_global<SignerCapabilityStore>(@harvest);
        account::create_signer_with_capability(&signer_cap_store.signer_capability)
    }
}

