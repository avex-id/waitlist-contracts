// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module mini_games::house_treasury {
    // === Imports ===
    use std::signer;

    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};

    use mini_games::resource_account_manager as resource_account;

    friend mini_games::dice_roll;
    friend mini_games::nft_lottery;

    // === Errors ===
    const E_CALLER_NOT_AUTHORIZED: u64 = 0;
    const E_COIN_TREASURY_DOES_NOT_EXIST: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_COIN_TREASURY_NOT_ACTIVE: u64 = 3;


    // === Structs ===

    /// Configuration and Treasury shared object, managed by the house.
    struct HouseTreasury<phantom CoinType> has key {
        // House's balance which also contains the accrued winnings of the house.
        balance: Coin<CoinType>,
        // Is this treasury active for use.
        is_active: bool
    }

    // === View Functions === 

    #[view]
    public fun get_treasury_coin_balance<CoinType>() : u64 acquires HouseTreasury {
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global<HouseTreasury<CoinType>>(resource_account::get_address());
        coin::value<CoinType>(&house_treasury.balance)
    }

    #[view]
    public fun is_treasury_active<CoinType>() : bool acquires HouseTreasury {
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global<HouseTreasury<CoinType>>(resource_account::get_address());
        house_treasury.is_active
    }

    // === Public Entry Functions ===

    public entry fun add_coins_to_house_treasury<CoinType>(
        sender: &signer,
        amount: u64,
    ) acquires HouseTreasury {
        assert!(signer::address_of(sender) == @mini_games, E_CALLER_NOT_AUTHORIZED);
        add_treasuty_if_not_exists<CoinType>();
        let house_treasury = borrow_global_mut<HouseTreasury<CoinType>>(resource_account::get_address());
        let coins = coin::withdraw<CoinType>(sender, amount);
        coin::merge<CoinType>(&mut house_treasury.balance, coins);
    }

    public entry fun withdraw_coins_from_house_treasury<CoinType>(
        sender: &signer,
        amount: u64,
    ) acquires HouseTreasury {
        assert!(signer::address_of(sender) == @mini_games, E_CALLER_NOT_AUTHORIZED);
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global_mut<HouseTreasury<CoinType>>(resource_account::get_address());
        assert!(coin::value<CoinType>(&house_treasury.balance) >= amount, E_INSUFFICIENT_BALANCE);
        let coins = coin::extract(&mut house_treasury.balance, amount);
        aptos_account::deposit_coins(signer::address_of(sender), coins);
    }

    public entry fun toggle_house_treasury<CoinType>(
        sender: &signer,
    ) acquires HouseTreasury {
        assert!(signer::address_of(sender) == @mini_games, E_CALLER_NOT_AUTHORIZED);
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global_mut<HouseTreasury<CoinType>>(resource_account::get_address());
        house_treasury.is_active = !house_treasury.is_active;
    }

    // === Public Friend Functions === 

    public(friend) fun merge_coins<CoinType>(
        coins : Coin<CoinType>
    ) acquires HouseTreasury {
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global_mut<HouseTreasury<CoinType>>(resource_account::get_address());
        let amount = coin::value<CoinType>(&coins);
        coin::merge<CoinType>(&mut house_treasury.balance, coins);
    }

    public(friend) fun extract_coins<CoinType>(
        amount: u64,
    ): Coin<CoinType> acquires HouseTreasury {
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global_mut<HouseTreasury<CoinType>>(resource_account::get_address());
        assert!(coin::value<CoinType>(&house_treasury.balance) >= amount, E_INSUFFICIENT_BALANCE);
        assert!(house_treasury.is_active, E_COIN_TREASURY_NOT_ACTIVE);
        coin::extract(&mut house_treasury.balance, amount)
    }

    public(friend) fun pause_treasury<CoinType>() acquires HouseTreasury {
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global_mut<HouseTreasury<CoinType>>(resource_account::get_address());
        house_treasury.is_active = false;
    }

    public(friend) fun resume_treasury<CoinType>() acquires HouseTreasury {
        assert!(exists<HouseTreasury<CoinType>>(resource_account::get_address()), E_COIN_TREASURY_DOES_NOT_EXIST);
        let house_treasury = borrow_global_mut<HouseTreasury<CoinType>>(resource_account::get_address());
        house_treasury.is_active = true;
    }

    public(friend) fun does_treasury_exist<CoinType>() : bool {
        exists<HouseTreasury<CoinType>>(resource_account::get_address())
    }

    // === Private Functions === 


    fun add_treasuty_if_not_exists<CoinType>() {
        if(!exists<HouseTreasury<CoinType>>(resource_account::get_address())){
            move_to(&resource_account::get_signer(), HouseTreasury<CoinType> { 
            balance: coin::zero<CoinType>(),
            is_active: true
        });
        }
    }


}