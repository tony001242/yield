#[test_only]
module yield::test_vault {
    use std::signer;
    use amnis::test_helpers;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use amnis::amapt_token;
    use amnis::stapt_token;
    use amnis::test_router;
    use amnis::stapt_token::StakedApt;
    use amnis::amapt_token::AmnisApt;
    use amnis::router;
    use yield::vault::{Vault, claim_interest};
    use yield::yield_package_manager;

    use yield::vault;

    const BPS_MAX: u128 = 10000;

    #[test(user = @0xdeadbeef)]
    fun test_mint_with_apt(user: &signer) {
        setup();
        // Commission rate is 10%.
        test_helpers::initialize_test_validator(@0xdollar1);
        test_helpers::mint_apt_to(user, 1000);
        let vault =
            vault::create_vault(test_helpers::deployer(), timestamp::now_seconds() + 1000);
        let deposit_amount = 1000 * test_helpers::one_apt();
        vault::deposit<AptosCoin>(user, vault, deposit_amount);
        // We need to deduct the add stake fee charged by delegation framework.
        deposit_amount = test_router::after_fee(deposit_amount);
        assert_principal_token_balance(user, vault, deposit_amount);
        assert_yield_token_balance(user, vault, deposit_amount);
    }

    #[test(user = @0xdeadbeef)]
    fun test_mint_with_amapt(user: &signer) {
        setup();
        // Commission rate is 10%.
        test_helpers::initialize_test_validator(@0xdollar1);
        test_helpers::mint_apt_to(user, 1000);
        let deposit_amount = 1000 * test_helpers::one_apt();
        router::deposit_entry(user, deposit_amount, signer::address_of(user));
        // We need to deduct the add stake fee charged by delegation framework.
        deposit_amount = test_router::after_fee(deposit_amount);

        let vault =
            vault::create_vault(test_helpers::deployer(), timestamp::now_seconds() + 1000);
        vault::deposit<AmnisApt>(user, vault, deposit_amount);
        assert_principal_token_balance(user, vault, deposit_amount);
        assert_yield_token_balance(user, vault, deposit_amount);
    }

    #[test(user = @0xdeadbeef)]
    fun test_mint_with_stapt(user: &signer) {
        setup();
        // Commission rate is 10%.
        test_helpers::initialize_test_validator(@0xdollar1);
        test_helpers::mint_apt_to(user, 1000);
        let deposit_amount = 1000 * test_helpers::one_apt();
        router::deposit_and_stake_entry(user, deposit_amount, signer::address_of(user));
        // We need to deduct the add stake fee charged by delegation framework.
        deposit_amount = test_router::after_fee(deposit_amount);

        let vault =
            vault::create_vault(test_helpers::deployer(), timestamp::now_seconds() + 1000);
        vault::deposit<StakedApt>(user, vault, deposit_amount);
        assert_principal_token_balance(user, vault, deposit_amount);
        assert_yield_token_balance(user, vault, deposit_amount);
    }

    #[test(user = @0xdeadbeef)]
    fun test_redeem_amapt(user: &signer) {
        setup();
        // Commission rate is 10%.
        test_helpers::initialize_test_validator(@0xdollar1);
        test_helpers::mint_apt_to(user, 2000);
        router::deposit_and_stake_entry(user, 2000 * test_helpers::one_apt(), signer::address_of(user));
        let deposit_amount = 1000 * test_helpers::one_apt();

        let vault =
            vault::create_vault(test_helpers::deployer(), timestamp::now_seconds() + 1000);
        vault::deposit<StakedApt>(user, vault, deposit_amount);
        timestamp::fast_forward_seconds(1000);
        assert_principal_token_balance(user, vault, deposit_amount);
        vault::redeem<AmnisApt>(user, vault, deposit_amount);
        assert_principal_token_balance(user, vault, 0);
        test_helpers::assert_amapt_balance(user, deposit_amount);
        // Yield token balance doesn't change.
        assert_yield_token_balance(user, vault, deposit_amount);
    }

    #[test(user = @0xdeadbeef)]
    fun test_redeem_stapt(user: &signer) {
        setup();
        // Commission rate is 10%.
        test_helpers::initialize_test_validator(@0xdollar1);
        test_helpers::mint_apt_to(user, 2000);
        let user_address = signer::address_of(user);
        router::deposit_and_stake_entry(user, 2000 * test_helpers::one_apt(), user_address);
        let deposit_amount = 1000 * test_helpers::one_apt();

        let vault =
            vault::create_vault(test_helpers::deployer(), timestamp::now_seconds() + 1000);
        vault::deposit<StakedApt>(user, vault, deposit_amount);

        // Some rewards are generated.
        test_helpers::end_epoch_and_update_rewards();
        assert_principal_token_balance(user, vault, deposit_amount);
        let balance_before = coin::balance<StakedApt>(user_address);
        vault::redeem<StakedApt>(user, vault, deposit_amount);
        assert!(vault::claimable(user_address, vault) > 0, 0);
        let balance_after = coin::balance<StakedApt>(user_address);
        assert_principal_token_balance(user, vault, 0);
        // Received less stAPT than before but should be the same in amAPT.
        assert!(balance_after - balance_before < deposit_amount, 0);
        router::unstake_entry(user, balance_after - balance_before, user_address);
        test_helpers::assert_amapt_balance(user, deposit_amount);
    }

    #[test(user = @0xdeadbeef)]
    fun test_claim_interest(user: &signer) {
        setup();
        // Commission rate is 10%.
        test_helpers::initialize_test_validator(@0xdollar1);
        test_helpers::mint_apt_to(user, 2000);
        let user_address = signer::address_of(user);
        let deposit_amount = 1000 * test_helpers::one_apt();
        router::deposit_and_stake_entry(user, deposit_amount, user_address);
        assert!(amapt_token::total_supply() == (stapt_token::total_amapt_staked() as u128), 0);
        deposit_amount = test_router::after_fee(deposit_amount);

        let vault =
            vault::create_vault(test_helpers::deployer(), timestamp::now_seconds() + 1000);
        vault::deposit<StakedApt>(user, vault, deposit_amount);
        assert_principal_token_balance(user, vault, deposit_amount);
        assert!(vault::claimable(user_address, vault) == 0, 0);

        // Some rewards are generated.
        let stapt_price_before = stapt_token::stapt_price();
        test_helpers::end_epoch_and_update_rewards();
        let stapt_price_after = stapt_token::stapt_price();
        claim_interest<AmnisApt>(user, vault);
        test_helpers::assert_amapt_balance(user, (stapt_price_after - stapt_price_before) * deposit_amount / stapt_token::precision_u64());

        // Claim interest multiple times shouldn't do anything.
        claim_interest<AmnisApt>(user, vault);
        test_helpers::assert_amapt_balance(user, (stapt_price_after - stapt_price_before) * deposit_amount / stapt_token::precision_u64());
    }

    fun assert_principal_token_balance(user: &signer, vault: Object<Vault>, amount: u64) {
        assert!(
            primary_fungible_store::balance(signer::address_of(user), vault::principal_token(vault)) == amount, 0);
    }

    fun assert_yield_token_balance(user: &signer, vault: Object<Vault>, amount: u64) {
        assert!(
            primary_fungible_store::balance(signer::address_of(user), vault::yield_token(vault)) == amount, 0);
    }

    fun setup() {
        test_helpers::set_up();
        yield_package_manager::initialize_for_test(test_helpers::deployer());
        vault::initialize();
    }
}
