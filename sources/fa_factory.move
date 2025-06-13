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
    const EINSUFFICIENT_CONTRACT_TOKENS: u64 = 104;

    struct ManagedFA has key {
        symbol: vector<u8>,
        mint: MintRef,
        burn: BurnRef,
        transfer: TransferRef,
        extend: ExtendRef,
        reserve: u64,           // APT reserve trong pool
        total_supply: u64,      // Total supply (cố định)
        circulating_supply: u64, // Số token đang lưu hành (bán ra ngoài)
        k: u64,                 // Constant cho bonding curve
        fee_rate: u64,          // Fee rate (basis points, e.g., 100 = 1%)
    }

    // Event structures
    #[event]
    struct TokenCreated has drop, store {
        symbol: vector<u8>,
        creator: address,
        total_supply: u64,
        k: u64,
    }

    #[event]
    struct TokenBought has drop, store {
        buyer: address,
        symbol: vector<u8>,
        apt_paid: u64,
        tokens_received: u64,
        new_circulating_supply: u64,
        new_reserve: u64,
    }

    #[event]
    struct TokenSold has drop, store {
        seller: address,
        symbol: vector<u8>,
        tokens_sold: u64,
        apt_received: u64,
        new_circulating_supply: u64,
        new_reserve: u64,
    }

    public entry fun create_token(
        admin: &signer,
        symbol: vector<u8>,
        name: vector<u8>,
        icon: vector<u8>,
        project_url: vector<u8>,
        decimals: u8,
        total_supply: u64,      // Fixed total supply
        k: u64,
        fee_rate: u64
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
        
        // Mint toàn bộ supply cho contract
        let asset = object::object_from_constructor_ref<Metadata>(constructor);
        let contract_store = primary_fungible_store::ensure_primary_store_exists(
            signer::address_of(&signer_for_asset), 
            asset
        );
        let total_tokens = fungible_asset::mint(&mint, total_supply);
        fungible_asset::deposit_with_ref(&transfer, contract_store, total_tokens);
        
        move_to(&signer_for_asset, ManagedFA {
            symbol,
            mint,
            burn,
            transfer,
            extend,
            reserve: 0,
            total_supply,
            circulating_supply: 0,  // Chưa có token nào được bán ra
            k,
            fee_rate,
        });

        // Emit event
        event::emit(TokenCreated {
            symbol,
            creator: signer::address_of(admin),
            total_supply,
            k,
        });
    }

    public fun get_metadata(symbol: vector<u8>): object::Object<Metadata> {
        let addr = object::create_object_address(&@fa_factory, symbol);
        object::address_to_object<Metadata>(addr)
    }

    // Buy tokens with APT - chuyển token từ contract sang buyer
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

        // Calculate tokens to transfer based on bonding curve
        let token_amount = compute_buy_amount(fa.k, fa.circulating_supply, net_amount);
        
        // Check contract has enough tokens
        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        let contract_store = primary_fungible_store::primary_store(
            signer::address_of(&contract_signer), 
            asset
        );
        assert!(fungible_asset::balance(contract_store) >= token_amount,
                error::invalid_argument(EINSUFFICIENT_CONTRACT_TOKENS));

        // Update state
        fa.reserve = fa.reserve + net_amount;
        fa.circulating_supply = fa.circulating_supply + token_amount;

        // Transfer APT from buyer to contract
        coin::transfer<AptosCoin>(buyer, signer::address_of(&contract_signer), apt_amount);

        // Transfer tokens from contract to buyer
        let buyer_store = primary_fungible_store::ensure_primary_store_exists(buyer_addr, asset);
        fungible_asset::transfer_with_ref(&fa.transfer, contract_store, buyer_store, token_amount);

        // Emit event
        event::emit(TokenBought {
            buyer: buyer_addr,
            symbol: fa.symbol,
            apt_paid: apt_amount,
            tokens_received: token_amount,
            new_circulating_supply: fa.circulating_supply,
            new_reserve: fa.reserve,
        });
    }

    // Sell tokens for APT - chuyển token từ seller về contract
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
        let apt_refund = compute_sell_amount(fa.k, fa.circulating_supply, token_amount);
        let fee = (apt_refund * fa.fee_rate) / 10000;
        let net_refund = apt_refund - fee;
        
        assert!(net_refund <= fa.reserve, error::invalid_argument(EINSUFFICIENT_FUNDS));

        // Update state
        fa.reserve = fa.reserve - apt_refund;
        fa.circulating_supply = fa.circulating_supply - token_amount;

        // Transfer tokens from seller to contract
        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        let contract_store = primary_fungible_store::primary_store(
            signer::address_of(&contract_signer), 
            asset
        );
        fungible_asset::transfer_with_ref(&fa.transfer, seller_store, contract_store, token_amount);

        // Transfer APT to seller
        coin::transfer<AptosCoin>(&contract_signer, seller_addr, net_refund);

        // Emit event
        event::emit(TokenSold {
            seller: seller_addr,
            symbol: fa.symbol,
            tokens_sold: token_amount,
            apt_received: net_refund,
            new_circulating_supply: fa.circulating_supply,
            new_reserve: fa.reserve,
        });
    }

    // Get current price for buying tokens
    #[view]
    public fun get_buy_price(symbol: vector<u8>, apt_amount: u64): u64 acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        
        let fee = (apt_amount * fa.fee_rate) / 10000;
        let net_amount = apt_amount - fee;
        compute_buy_amount(fa.k, fa.circulating_supply, net_amount)
    }

    // Get current price for selling tokens
    #[view]
    public fun get_sell_price(symbol: vector<u8>, token_amount: u64): u64 acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        
        let apt_refund = compute_sell_amount(fa.k, fa.circulating_supply, token_amount);
        let fee = (apt_refund * fa.fee_rate) / 10000;
        apt_refund - fee
    }

    // Get token info
    #[view]
    public fun get_token_info(symbol: vector<u8>): (u64, u64, u64, u64, u64) acquires ManagedFA {
        let asset = get_metadata(symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        (fa.reserve, fa.total_supply, fa.circulating_supply, fa.k, fa.fee_rate)
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

    // Bonding curve cho việc mua token
    fun compute_buy_amount(k: u64, current_circulating: u64, apt_paid: u64): u64 {
        // Giá tăng theo số lượng circulating
        let adjusted_k = k + (current_circulating / 1000000);
        if (adjusted_k == 0) {
            apt_paid
        } else {
            apt_paid / adjusted_k
        }
    }

    // Bonding curve cho việc bán token
    fun compute_sell_amount(k: u64, current_circulating: u64, token_amount: u64): u64 {
        // Tính APT nhận được khi bán
        let new_circulating = current_circulating - token_amount;
        let adjusted_k = k + (new_circulating / 1000000);
        if (adjusted_k == 0) {
            token_amount
        } else {
            token_amount * adjusted_k
        }
    }
}