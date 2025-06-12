module fa_factory::fa_factory {
    use std::signer;
    use std::option;
    use std::error;
    use std::string;
    use aptos_framework::object;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, BurnRef, TransferRef};
    use aptos_framework::primary_fungible_store;

    const ENOT_OWNER: u64 = 100;
    const EINSUFFICIENT_FUNDS: u64 = 101;

    struct ManagedFA has key {
        symbol: vector<u8>,
        mint: MintRef,
        burn: BurnRef,
        transfer: TransferRef,
        reserve: u64,
        supply: u64,
        k: u64,
    }

    public entry fun create_token(
        admin: &signer,
        symbol: vector<u8>,
        name: vector<u8>,
        icon: vector<u8>,
        project_url: vector<u8>,
        decimals: u8,
        k: u64
    ) {
        let constructor = &object::create_named_object(admin, symbol);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor,
            option::none(),
            string::utf8(name),
            string::utf8(symbol),
            decimals,
            string::utf8(icon),
            string::utf8(project_url)
        );

        let mint = fungible_asset::generate_mint_ref(constructor);
        let burn = fungible_asset::generate_burn_ref(constructor);
        let transfer = fungible_asset::generate_transfer_ref(constructor);

        let signer_for_asset = object::generate_signer(constructor);
        move_to(&signer_for_asset, ManagedFA {
            symbol,
            mint,
            burn,
            transfer,
            reserve: 0,
            supply: 0,
            k,
        });
    }

    public fun get_metadata(symbol: vector<u8>): object::Object<Metadata> {
        let addr = object::create_object_address(&@fa_factory, symbol);
        object::address_to_object<Metadata>(addr)
    }

    public entry fun buy(
        admin: &signer,
        symbol: vector<u8>,
        buyer: address,
        amount_paid: u64
    ) acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global_mut<ManagedFA>(object::object_address(&asset));

        assert!(object::is_owner(asset, signer::address_of(admin)), error::permission_denied(ENOT_OWNER));

        let mint_amount = compute_mint_amount(fa.k, fa.supply, amount_paid);
        fa.reserve = fa.reserve + amount_paid;
        fa.supply = fa.supply + mint_amount;

        let buyer_store = primary_fungible_store::ensure_primary_store_exists(buyer, asset);
        let minted = fungible_asset::mint(&fa.mint, mint_amount);
        fungible_asset::deposit_with_ref(&fa.transfer, buyer_store, minted);
    }

    public entry fun sell(
        admin: &signer,
        symbol: vector<u8>,
        seller: address,
        amount_token: u64
    ) acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global_mut<ManagedFA>(object::object_address(&asset));

        assert!(object::is_owner(asset, signer::address_of(admin)), error::permission_denied(ENOT_OWNER));

        let refund = compute_refund_amount(fa.k, fa.supply, amount_token);
        assert!(refund <= fa.reserve, error::invalid_argument(EINSUFFICIENT_FUNDS));

        fa.reserve = fa.reserve - refund;
        fa.supply = fa.supply - amount_token;

        let seller_wallet = primary_fungible_store::primary_store(seller, asset);
        fungible_asset::burn_from(&fa.burn, seller_wallet, amount_token);
    }

    fun compute_mint_amount(k: u64, _supply: u64, amount_paid: u64): u64 {
        amount_paid / k
    }

    fun compute_refund_amount(k: u64, _supply: u64, amount_token: u64): u64 {
        amount_token * k
    }
}
