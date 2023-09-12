module yield::vault {
    use amnis::router;
    use amnis::amapt_token::AmnisApt;
    use amnis::stapt_token::{Self, StakedApt};

    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::type_info;
    use std::signer;
    use aptos_std::math64;
    use aptos_framework::aptos_account;
    use aptos_framework::primary_fungible_store;
    use yield::coin_wrapper;
    use yield::liquidity_pool;

    use yield::token;

    /// Cannot deposit into a vault that has expired.
    const EVAULT_HAS_EXPIRED: u64 = 1;
    /// Coin type of deposit is not supported.
    const EUNSUPPORTED_COIN_TYPE: u64 = 2;
    /// Only governance can create a vault.
    const EONLY_GOVERNANCE_CAN_CREATE_VAULT: u64 = 3;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Vault has key {
        expiration_secs: u64,
        underlying_asset: Coin<StakedApt>,
        principal_token: Object<Metadata>,
        yield_token: Object<Metadata>,

        last_exchange_rate: u64,
        per_token_interest_stored: u64,
        per_token_interest_at_last_claim: SmartTable<address, u64>,
        interest_claimable: SmartTable<address, u64>,
    }

    #[view]
    public fun principal_token(vault: Object<Vault>): Object<Metadata> acquires Vault {
        let vault = borrow_global<Vault>(object::object_address(&vault));
        vault.principal_token
    }

    #[view]
    public fun expiration_secs(vault: Object<Vault>): u64 acquires Vault {
        let vault = borrow_global<Vault>(object::object_address(&vault));
        vault.expiration_secs
    }

    #[view]
    public fun yield_token(vault: Object<Vault>): Object<Metadata> acquires Vault {
        let vault = borrow_global<Vault>(object::object_address(&vault));
        vault.yield_token
    }

    #[view]
    public fun is_expired(vault: Object<Vault>): bool acquires Vault {
        let vault = borrow_global<Vault>(object::object_address(&vault));
        timestamp::now_seconds() >= vault.expiration_secs
    }

    #[view]
    public fun claimable(user: address, vault: Object<Vault>): u64 acquires Vault {
        update_interest(user, vault);
        let vault = borrow_global<Vault>(object::object_address(&vault));
        let stAPT_price = stapt_token::stapt_price();
        let amAPT_amount = *smart_table::borrow_with_default(&vault.interest_claimable, user, &0);
        math64::mul_div(amAPT_amount, stapt_token::precision_u64(), stAPT_price)
    }

    #[view]
    public fun stapt_mint_amount_out(amount_in: u64): u64 {
        let stAPT_price = stapt_token::stapt_price();
        amount_in * stAPT_price / stapt_token::precision_u64()
    }

    #[view]
    public fun total_stapt_staked(vault: Object<Vault>): u64 acquires Vault {
        coin::value(&borrow_global<Vault>(object::object_address(&vault)).underlying_asset)
    }

    #[view]
    public fun yt_reward_per_epoch(vault: Object<Vault>): (u64, u64) acquires Vault {
        let vault = borrow_global<Vault>(object::object_address(&vault));
        let total_stapt_staked = coin::value(&vault.underlying_asset);
        let total_supply = (token::total_supply(vault.yield_token) as u64);
        let (effective_reward_rate, reward_rate_denom) = router::current_reward_rate();
        let reward_per_epoch = math64::mul_div(total_stapt_staked, effective_reward_rate, total_supply);
        (reward_per_epoch, reward_rate_denom)
    }

    public entry fun initialize() {
        coin_wrapper::initialize();
        liquidity_pool::initialize();
    }

    public entry fun create_vault_entry(governance: &signer, expiration_secs: u64) {
        create_vault(governance, expiration_secs);
    }

    public fun create_vault(governance: &signer, expiration_secs: u64): Object<Vault> {
        assert!(signer::address_of(governance) == @deployer, EONLY_GOVERNANCE_CAN_CREATE_VAULT);

        let (principal_token, yield_token) = token::initialize_principal_and_yield_tokens(
            coin::symbol<StakedApt>(),
            coin::decimals<StakedApt>(),
            expiration_secs,
        );
        let vault_constructor_ref = &object::create_object(@yield);
        let vault_signer = &object::generate_signer(vault_constructor_ref);
        move_to(vault_signer, Vault {
            expiration_secs,
            underlying_asset: coin::zero(),
            principal_token,
            yield_token,

            last_exchange_rate: stapt_token::stapt_price(),
            per_token_interest_stored: 0,
            per_token_interest_at_last_claim: smart_table::new(),
            interest_claimable: smart_table::new(),
        });
        object::object_from_constructor_ref(vault_constructor_ref)
    }

    public entry fun deposit<CoinType>(owner: &signer, vault: Object<Vault>, amount: u64) acquires Vault {
        // Calculate unclaimed interests. This must happen before any deposits.
        let owner_address = signer::address_of(owner);
        update_interest(owner_address, vault);

        let vault = borrow_global_mut<Vault>(object::object_address(&vault));
        assert!(timestamp::now_seconds() < vault.expiration_secs, EVAULT_HAS_EXPIRED);

        // Convert input to stAPT.
        let coin_type = type_info::type_name<CoinType>();
        let stapt = if (coin_type == type_info::type_name<AptosCoin>()) {
            router::deposit_and_stake(coin::withdraw<AptosCoin>(owner, amount))
        } else if (coin_type == type_info::type_name<AmnisApt>()) {
            router::stake(coin::withdraw<AmnisApt>(owner, amount))
        } else if (coin_type == type_info::type_name<StakedApt>()) {
            coin::withdraw<StakedApt>(owner, amount)
        } else {
            abort EUNSUPPORTED_COIN_TYPE
        };
        let amount_to_mint =
            math64::mul_div(coin::value(&stapt), stapt_token::stapt_price(), stapt_token::precision_u64());
        coin::merge(&mut vault.underlying_asset, stapt);

        // Mint amount of principal and yield tokens equivalent to the amount of amAPT (converted from stAPT using
        // current exchange rate).
        token::mint(vault.principal_token, amount_to_mint, owner_address);
        token::mint(vault.yield_token, amount_to_mint, owner_address);
    }

    public entry fun redeem<CoinType>(owner: &signer, vault: Object<Vault>, amount: u64) acquires Vault {
        // Calculate unclaimed interests. This must happen before any deposits.
        let owner_address = signer::address_of(owner);
        update_interest(owner_address, vault);

        let vault = borrow_global_mut<Vault>(object::object_address(&vault));
        // Burn principal tokens only if vault has expired. Otherwise burn both principal and yield tokens.
        if (timestamp::now_seconds() < vault.expiration_secs) {
            token::burn(vault.yield_token, amount, owner_address);
        };
        token::burn(vault.principal_token, amount, owner_address);

        distribute<CoinType>(amount, vault, owner_address);
    }

    public entry fun claim_interest<CoinType>(owner: &signer, vault: Object<Vault>) acquires Vault {
        let owner_address = signer::address_of(owner);
        update_interest(owner_address, vault);

        let vault = borrow_global_mut<Vault>(object::object_address(&vault));
        let claimable = *smart_table::borrow_with_default(&vault.interest_claimable, owner_address, &0);
        if (claimable > 0) {
            smart_table::remove(&mut vault.interest_claimable, owner_address);
            distribute<CoinType>(claimable, vault, owner_address);
        };
    }

    public entry fun update_interest(owner: address, vault: Object<Vault>) acquires Vault {
        let vault = borrow_global_mut<Vault>(object::object_address(&vault));
        let current_rate = stapt_token::stapt_price();
        // Update total per token interest. We need this to compute how much interest each user is entitled to.
        if (current_rate > vault.last_exchange_rate) {
            let delta = current_rate - vault.last_exchange_rate;
            let new_per_token = math64::mul_div(
                delta, coin::value(&vault.underlying_asset), (token::total_supply(vault.yield_token) as u64));
            vault.per_token_interest_stored = vault.per_token_interest_stored + new_per_token;
        };
        vault.last_exchange_rate = current_rate;

        let per_token_interest_at_last_claim = smart_table::borrow_mut_with_default(
            &mut vault.per_token_interest_at_last_claim, owner, vault.per_token_interest_stored);
        if (vault.per_token_interest_stored > *per_token_interest_at_last_claim) {
            let unclaimed_per_token = vault.per_token_interest_stored - *per_token_interest_at_last_claim;
            // per_token_interest_stored includes a 1e8 multiplier for precision.
            let unclaimed_interest = math64::mul_div(
                unclaimed_per_token, primary_fungible_store::balance(owner, vault.yield_token), stapt_token::precision_u64());
            *per_token_interest_at_last_claim = vault.per_token_interest_stored;
            let claimable = smart_table::borrow_mut_with_default(&mut vault.interest_claimable, owner, 0);
            *claimable = *claimable + unclaimed_interest;
        };
    }

    fun distribute<CoinType>(amount: u64, vault: &mut Vault, recipient: address) {
        let amount_to_redeem = math64::mul_div(amount, stapt_token::precision_u64(), stapt_token::stapt_price());
        let stapt_to_redeem = coin::extract(&mut vault.underlying_asset, amount_to_redeem);
        let coin_type = type_info::type_name<CoinType>();
        if (coin_type == type_info::type_name<AmnisApt>()) {
            aptos_account::deposit_coins(recipient, router::unstake(stapt_to_redeem));
        } else if (coin_type == type_info::type_name<StakedApt>()) {
            aptos_account::deposit_coins(recipient, stapt_to_redeem);
        } else {
            abort EUNSUPPORTED_COIN_TYPE
        };
    }
}