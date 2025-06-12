module fa_factory::fa_factory {
    use std::signer;
    use std::option;
    use std::error;
    use std::string;
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, BurnRef, TransferRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::event;

    const ENOT_OWNER: u64 = 100;
    const EINSUFFICIENT_FUNDS: u64 = 101;
    const EINSUFFICIENT_TOKEN_BALANCE: u64 = 102;
    const EINVALID_AMOUNT: u64 = 103;

    struct ManagedFA has key {
        symbol: vector<u8>,
        mint: MintRef,
        burn: BurnRef,
        transfer: TransferRef,
        extend: ExtendRef,  // Add ExtendRef for generating signer
        reserve: u64,      // APT reserve trong pool
        supply: u64,       // Token supply hiện tại
        k: u64,           // Constant cho bonding curve
        fee_rate: u64,    // Fee rate (basis points, e.g., 100 = 1%)
    }

    // Event structures
    #[event]
    struct TokenCreated has drop, store {
        symbol: vector<u8>,
        creator: address,
        k: u64,
    }

    #[event]
    struct TokenBought has drop, store {
        buyer: address,
        symbol: vector<u8>,
        apt_paid: u64,
        tokens_received: u64,
        new_supply: u64,
        new_reserve: u64,
    }

    #[event]
    struct TokenSold has drop, store {
        seller: address,
        symbol: vector<u8>,
        tokens_sold: u64,
        apt_received: u64,
        new_supply: u64,
        new_reserve: u64,
    }

    public entry fun create_token(
        admin: &signer,
        symbol: vector<u8>,
        name: vector<u8>,
        icon: vector<u8>,
        project_url: vector<u8>,
        decimals: u8,
        k: u64,
        fee_rate: u64  // Fee rate in basis points (100 = 1%)
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
        let extend = object::generate_extend_ref(constructor);

        let signer_for_asset = object::generate_signer(constructor);
        
        // Register the contract to receive APT
        coin::register<AptosCoin>(&signer_for_asset);
        
        move_to(&signer_for_asset, ManagedFA {
            symbol,
            mint,
            burn,
            transfer,
            extend,
            reserve: 0,
            supply: 0,
            k,
            fee_rate,
        });

        // Emit event
        event::emit(TokenCreated {
            symbol,
            creator: signer::address_of(admin),
            k,
        });
    }

    public fun get_metadata(symbol: vector<u8>): object::Object<Metadata> {
        let addr = object::create_object_address(&@fa_factory, symbol);
        object::address_to_object<Metadata>(addr)
    }

    // Buy tokens with APT - anyone can call this
    public entry fun buy_tokens(
        buyer: &signer,
        symbol: vector<u8>,
        apt_amount: u64
    ) acquires ManagedFA {
        assert!(apt_amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        
        let asset = get_metadata(symbol);
        let fa = borrow_global_mut<ManagedFA>(object::object_address(&asset));
        let buyer_addr = signer::address_of(buyer);

        // Check buyer has enough APT
        assert!(coin::balance<AptosCoin>(buyer_addr) >= apt_amount, 
                error::invalid_argument(EINSUFFICIENT_FUNDS));

        // Calculate fee and net amount
        let fee = (apt_amount * fa.fee_rate) / 10000;
        let net_amount = apt_amount - fee;

        // Calculate tokens to mint based on bonding curve
        let mint_amount = compute_mint_amount(fa.k, fa.supply, net_amount);
        
        // Update state
        fa.reserve = fa.reserve + net_amount;
        fa.supply = fa.supply + mint_amount;

        // Transfer APT from buyer to contract
        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        coin::transfer<AptosCoin>(buyer, signer::address_of(&contract_signer), apt_amount);

        // Mint and transfer tokens to buyer
        let buyer_store = primary_fungible_store::ensure_primary_store_exists(buyer_addr, asset);
        let minted = fungible_asset::mint(&fa.mint, mint_amount);
        fungible_asset::deposit_with_ref(&fa.transfer, buyer_store, minted);

        // Emit event
        event::emit(TokenBought {
            buyer: buyer_addr,
            symbol: fa.symbol,
            apt_paid: apt_amount,
            tokens_received: mint_amount,
            new_supply: fa.supply,
            new_reserve: fa.reserve,
        });
    }

    // Sell tokens for APT - anyone can call this
    public entry fun sell_tokens(
        seller: &signer,
        symbol: vector<u8>,
        token_amount: u64
    ) acquires ManagedFA {
        assert!(token_amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        
        let asset = get_metadata(symbol);
        let fa = borrow_global_mut<ManagedFA>(object::object_address(&asset));
        let seller_addr = signer::address_of(seller);

        // Check seller has enough tokens
        let seller_store = primary_fungible_store::primary_store(seller_addr, asset);
        assert!(fungible_asset::balance(seller_store) >= token_amount,
                error::invalid_argument(EINSUFFICIENT_TOKEN_BALANCE));

        // Calculate APT to return based on bonding curve
        let apt_refund = compute_refund_amount(fa.k, fa.supply, token_amount);
        let fee = (apt_refund * fa.fee_rate) / 10000;
        let net_refund = apt_refund - fee;
        
        assert!(net_refund <= fa.reserve, error::invalid_argument(EINSUFFICIENT_FUNDS));

        // Update state
        fa.reserve = fa.reserve - apt_refund;
        fa.supply = fa.supply - token_amount;

        // Burn tokens from seller
        fungible_asset::burn_from(&fa.burn, seller_store, token_amount);

        // Transfer APT to seller
        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        coin::transfer<AptosCoin>(&contract_signer, seller_addr, net_refund);

        // Emit event
        event::emit(TokenSold {
            seller: seller_addr,
            symbol: fa.symbol,
            tokens_sold: token_amount,
            apt_received: net_refund,
            new_supply: fa.supply,
            new_reserve: fa.reserve,
        });
    }

    // Get current price for buying tokens
    public fun get_buy_price(symbol: vector<u8>, apt_amount: u64): u64 acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        
        let fee = (apt_amount * fa.fee_rate) / 10000;
        let net_amount = apt_amount - fee;
        compute_mint_amount(fa.k, fa.supply, net_amount)
    }

    // Get current price for selling tokens
    public fun get_sell_price(symbol: vector<u8>, token_amount: u64): u64 acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        
        let apt_refund = compute_refund_amount(fa.k, fa.supply, token_amount);
        let fee = (apt_refund * fa.fee_rate) / 10000;
        apt_refund - fee
    }

    // Get token info
    public fun get_token_info(symbol: vector<u8>): (u64, u64, u64, u64) acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        (fa.reserve, fa.supply, fa.k, fa.fee_rate)
    }

    // Admin function to withdraw fees
    public entry fun withdraw_fees(
        admin: &signer,
        symbol: vector<u8>,
        amount: u64
    ) acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global_mut<ManagedFA>(object::object_address(&asset));
        
        assert!(object::is_owner(asset, signer::address_of(admin)), 
                error::permission_denied(ENOT_OWNER));
        
        let contract_balance = coin::balance<AptosCoin>(object::object_address(&asset));
        let available_fees = contract_balance - fa.reserve;
        assert!(amount <= available_fees, error::invalid_argument(EINSUFFICIENT_FUNDS));

        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        coin::transfer<AptosCoin>(&contract_signer, signer::address_of(admin), amount);
    }

    // Improved bonding curve: price increases as supply increases
    fun compute_mint_amount(k: u64, current_supply: u64, apt_paid: u64): u64 {
        // Simple linear bonding curve: price = k * supply
        // tokens = apt_paid / (k + current_supply/1000000)
        let adjusted_k = k + (current_supply / 1000000);
        if (adjusted_k == 0) {
            apt_paid
        } else {
            apt_paid / adjusted_k
        }
    }

    fun compute_refund_amount(k: u64, current_supply: u64, token_amount: u64): u64 {
        // Reverse of mint calculation
        let new_supply = current_supply - token_amount;
        let adjusted_k = k + (new_supply / 1000000);
        if (adjusted_k == 0) {
            token_amount
        } else {
            token_amount * adjusted_k
        }
    }
}