Summary of Changes in scripts.move🎯
1. Imports:

❌ Removed: aptos_framework::coin
✅ Added: aptos_framework::fungible_asset::Metadata
✅ Added: aptos_framework::primary_fungible_store
✅ Added: aptos_framework::object::Object

2. All Functions:

coin::withdraw → primary_fungible_store::withdraw
coin::deposit → primary_fungible_store::deposit
Removed all coin::is_account_registered checks
Removed all coin::register calls

3. Register Pool Functions:

Added stake_metadata: Object<Metadata> parameter
Added reward_metadata: Object<Metadata> parameter

4. Stake Functions:

Added stake_metadata: Object<Metadata> parameter

5. Deposit Rewards:

Added reward_metadata: Object<Metadata> parameter

Key Benefit: FA is much simpler! No registration checks needed! 😊


## Key Changes in stake.move (Coin → FA)

**1. Imports:**
```move
// Added:
use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset, FungibleStore};
use aptos_framework::primary_fungible_store;
use aptos_framework::object::{Self, Object};

// Removed:
use aptos_framework::coin::{Self, Coin};
```

**2. StakePool Struct:**
```move
// OLD:
stake_coins: Coin<S>,
reward_coins: Coin<R>,

// NEW:
stake_metadata: Object<Metadata>,   // Identifies token type
reward_metadata: Object<Metadata>,
stake_store: address,               // Pool's store address
reward_store: address,
```

**3. Function Signatures Changed:**

| Function | Old Return/Param | New Return/Param |
|----------|-----------------|------------------|
| `register_pool` | `Coin<R>` param | `FungibleAsset` + metadata objects |
| `deposit_reward_coins` | `Coin<R>` param | `FungibleAsset` param |
| `stake` | `Coin<S>` param | `FungibleAsset` param |
| `unstake` | Returns `Coin<S>` | Returns `FungibleAsset` |
| `harvest` | Returns `Coin<R>` | Returns `FungibleAsset` |
| `emergency_unstake` | Returns `Coin<S>` | Returns `FungibleAsset` |
| `withdraw_to_treasury` | Returns `Coin<R>` | Returns `FungibleAsset` |

**4. Storage Operations:**
```move
// OLD:
coin::value(&pool.stake_coins)
coin::merge(&mut pool.stake_coins, coins)
coin::extract(&mut pool.stake_coins, amount)

// NEW:
fungible_asset::balance(stake_store)
fungible_asset::deposit(stake_store, coins)
fungible_asset::withdraw(user, stake_store, amount)
```

**5. Pool Initialization:**
```move
// NEW: Create secondary fungible stores
let stake_store_constructor = object::create_object(owner_addr);
let stake_store = fungible_asset::create_store(&stake_store_constructor, stake_metadata);
let stake_store_addr = object::object_address(&stake_store);
```

**6. Decimals:**
```move
// OLD:
coin::decimals<R>()

// NEW:
fungible_asset::decimals(reward_metadata)
```

**Main Concept:** Instead of storing `Coin<S>` directly, we now store FAs in secondary stores and track their addresses. All operations use `fungible_asset` functions instead of `coin` functions.