module nft::raffle {
    use std::bcs;
    use std::hash;
    use std::signer;
    use std::vector;
    use std::string::{Self, String};

    use aptos_std::object::{Self, Object};
    use aptos_std::smart_vector::{Self, SmartVector};
    use aptos_std::big_vector::{Self, BigVector};
    use aptos_std::table_with_length::{Self, TableWithLength};

    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::table::{Self, Table};
    use aptos_framework::timestamp;
    use aptos_framework::transaction_context;
    use aptos_framework::type_info;

    use aptos_token::token::{Self as tokenv1, Token as TokenV1};
    use aptos_token::token_transfers;
    use aptos_token_objects::token::{Token as TokenV2};

    use nft::resource_account_manager as resource_account;

    const E_ERROR_UNAUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_TICKETS: u64 = 2;
    const E_ERROR_RAFFLE_PAUSED: u64 = 3;
    const E_ERROR_INVALID_TYPE: u64 = 4;
    const E_RAFFLE_NOT_ENDED: u64 = 5;
    const E_ERROR_INVALID_NUM_WINNERS: u64 = 6;
    const E_NO_PARTICIPANTS: u64 = 7;
    const E_EXCESSIVE_TICKETS: u64 = 8;
    const E_CANNOT_USE_EXCESSIVE_TICKETS: u64 = 9;

    struct RaffleManager has key {
        tickets: Table<address, u64>,
        global_active: bool,
    }

    struct CoinRaffleManager<phantom X> has key {
        coin_raffles: Table<u64, CoinRaffle<X>>,
        coin_raffle_count: u64,
    }

    struct NftRaffleManager has key {
        nft_v1_raffles: Table<u64, NFTRaffle>,
        nft_v2_raffles: Table<u64, NFTV2Raffle>,
        nft_v1_raffle_count: u64,
        nft_v2_raffle_count: u64,
    }



    struct CoinRaffle<phantom X> has key, store {
        coin: Coin<X>,
        participants: SmartVector<address>,
        active: bool,
    }

    struct NFTRaffle has key, store {
        nft: TokenV1,
        participants: SmartVector<address>,
        active: bool,
    }

    struct NFTV2Raffle has key, store {
        nft: Object<TokenV2>,
        participants: SmartVector<address>,
        active: bool,
    }

    #[event]
    struct TicketMintEvent has drop, store {
        user_address: address,
        ticket_amount: u64,
        timestamp: u64,
    }

    #[event]
    struct RaffleEntryEvent has drop, store {
        coin_type: String,
        raffle_type: u64,
        raffle_id: u64,
        tickets_used: u64,
        user: address,
    }


    // ======================== Entry functions ========================

    public entry fun add_coin_raffle<X>(admin: &signer, coin_amount: u64) 
    acquires RaffleManager, CoinRaffleManager {
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        assert!(check_status(), E_ERROR_RAFFLE_PAUSED);
        let coin = coin::withdraw<X>(admin, coin_amount);
        if(!exists<CoinRaffleManager<X>>(resource_account::get_address())) {
            move_to(&resource_account::get_signer(), CoinRaffleManager<X> {
                coin_raffles: table::new<u64, CoinRaffle<X>>(),
                coin_raffle_count: 0,
            });

            let coin_raffle_manager = borrow_global_mut<CoinRaffleManager<X>>(resource_account::get_address());
            table::add(&mut coin_raffle_manager.coin_raffles, 0, CoinRaffle<X> {
                coin,
                participants: smart_vector::empty_with_config<address>(10, 200),
                active: false,
            });
            coin_raffle_manager.coin_raffle_count = 1;

        } else {
            let coin_raffle_manager = borrow_global_mut<CoinRaffleManager<X>>(resource_account::get_address());
            let coin_raffle_count = coin_raffle_manager.coin_raffle_count;
            table::add(&mut coin_raffle_manager.coin_raffles, coin_raffle_count, CoinRaffle<X> {
                coin,
                participants: smart_vector::empty_with_config<address>(10, 200),
                active: false,
            });
            coin_raffle_manager.coin_raffle_count = coin_raffle_count + 1;
            
        }
    }

    // public entry fun empty_participants_array<X>(admin: &signer, num_participants: u64) acquires CoinRaffle {
    //     assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
    //     let coin_raffle = borrow_global_mut<CoinRaffle<X>>(resource_account::get_address());
    //     let mut_participants = &mut coin_raffle.participants;
    //      smart_vector::clear(mut_participants);
    //     for (i in 0..num_participants) {
    //         smart_vector::pop_back(mut_participants);
    //     }
    // }

    public entry fun add_nft_raffle(
        admin: &signer, 
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64
    ) acquires RaffleManager, NftRaffleManager{
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        assert!(check_status(), E_ERROR_RAFFLE_PAUSED);
        
        let raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
        let nft_v1_raffle_count = raffle_manager.nft_v1_raffle_count;
        let token_id = tokenv1::create_token_id_raw(token_creator, token_collection, token_name, token_property_version);
        let nft = tokenv1::withdraw_token(admin, token_id, 1);

        table::add(&mut raffle_manager.nft_v1_raffles, nft_v1_raffle_count, NFTRaffle {
            nft,
            participants: smart_vector::empty<address>(),
            active: false,
        });

        raffle_manager.nft_v1_raffle_count = nft_v1_raffle_count + 1;
    }

    public entry fun add_nft_v2_raffle(admin: &signer, nft: Object<TokenV2>) 
    acquires RaffleManager, NftRaffleManager {
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        assert!(check_status(), E_ERROR_RAFFLE_PAUSED);

        let raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
        let nft_v2_raffle_count = raffle_manager.nft_v2_raffle_count;
        table::add(&mut raffle_manager.nft_v2_raffles, nft_v2_raffle_count, NFTV2Raffle {
            nft,
            participants: smart_vector::empty<address>(),
            active: false,
        });

        raffle_manager.nft_v2_raffle_count = nft_v2_raffle_count + 1;
    }

    public entry fun mint_ticket(admin: &signer, to: address, amount: u64)
    acquires RaffleManager {
        assert!(check_status(), E_ERROR_RAFFLE_PAUSED);
        let admin_address = signer::address_of(admin);
        let resource_address = resource_account::get_address();
        // assert!(amount < 101, E_EXCESSIVE_TICKETS);

        // assert!((admin_address == @nft) || (admin_address == resource_address), E_ERROR_UNAUTHORIZED);
        assert!(check_caller_address(admin_address), E_ERROR_UNAUTHORIZED);

        let tickets = &mut borrow_global_mut<RaffleManager>(resource_address).tickets;
        let current_amount = table::borrow_mut_with_default(tickets, to, 0);
        *current_amount = *current_amount + amount;

        emit_ticket_mint_event(to, amount)
    }

    public entry fun enter_raffle<X>(
        sender: &signer,
        raffle_type: u64,
        raffle_id: u64,
        tickets_to_use: u64
    ) acquires RaffleManager, CoinRaffleManager, NftRaffleManager{
        assert!(check_status(), E_ERROR_RAFFLE_PAUSED);
        assert!(tickets_to_use < 5000 , E_CANNOT_USE_EXCESSIVE_TICKETS);

        let raffle_manager = borrow_global_mut<RaffleManager>(resource_account::get_address());

        let (is_active, participants) = if (raffle_type == 0) {
            let coin_raffle_manager = borrow_global_mut<CoinRaffleManager<X>>(resource_account::get_address());
            let raffle = table::borrow_mut(&mut coin_raffle_manager.coin_raffles, raffle_id);
            emit_raffle_entry_event(type_info::type_name<X>(), raffle_type, raffle_id, tickets_to_use, signer::address_of(sender));
            (raffle.active, &mut raffle.participants)

        } else if (raffle_type == 1) {
            let nft_raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
            let raffle = table::borrow_mut(&mut nft_raffle_manager.nft_v1_raffles, raffle_id);
            emit_raffle_entry_event(string::utf8(b"0x1::string::string"), raffle_type, raffle_id, tickets_to_use, signer::address_of(sender));
            (raffle.active, &mut raffle.participants)
        } else if (raffle_type ==2) {
            let nft_raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
            let raffle = table::borrow_mut(&mut nft_raffle_manager.nft_v2_raffles, raffle_id);
            emit_raffle_entry_event(string::utf8(b"0x1::string::string"), raffle_type, raffle_id, tickets_to_use, signer::address_of(sender));
            (raffle.active, &mut raffle.participants)
        } else {
            abort E_ERROR_INVALID_TYPE
        };
        assert!(is_active == true, E_ERROR_RAFFLE_PAUSED);

        let tickets = &mut raffle_manager.tickets;
        let current_amount = table::borrow_mut(tickets, signer::address_of(sender));
        assert!(*current_amount >= tickets_to_use, E_INSUFFICIENT_TICKETS);
        *current_amount = *current_amount - tickets_to_use;
        for ( i in 0..tickets_to_use){
            smart_vector::push_back(participants, signer::address_of(sender));
        };

        
    } 

    public entry fun pick_winner_coin_raffle<X>(admin: &signer, raffle_id: u64, num_winners: u64) 
    acquires RaffleManager, CoinRaffleManager {
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        assert!(check_status(), E_ERROR_RAFFLE_PAUSED);
        assert!(num_winners > 0, E_ERROR_INVALID_NUM_WINNERS);
        
        let coin_raffle_manager = borrow_global_mut<CoinRaffleManager<X>>(resource_account::get_address());
        let coin_raffle = table::borrow_mut(&mut coin_raffle_manager.coin_raffles, raffle_id);
        assert!(!coin_raffle.active, E_RAFFLE_NOT_ENDED);
        let num_coins = coin::value(&coin_raffle.coin);
        num_coins = num_coins / num_winners;

        let i = 0;
        
        while( i < num_winners ) {
            i = i + 1;
            let rand_num = rand_u64_range(i);
            let num_participants = smart_vector::length(&coin_raffle.participants);
            assert!(num_participants > 0, E_NO_PARTICIPANTS);
            let winner = smart_vector::borrow(&mut coin_raffle.participants, rand_num % num_participants);
            let coin = coin::extract(&mut coin_raffle.coin, num_coins);
            aptos_account::deposit_coins(*winner, coin);
        };

        // smart_vector::clear(&mut coin_raffle.participants);
        coin_raffle.active = false;
    }

    public entry fun pick_winner_nft_raffle(admin: &signer, raffle_type: u64, raffle_id: u64) 
    acquires RaffleManager, NftRaffleManager{
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        assert!(check_status(), E_ERROR_RAFFLE_PAUSED);

        let rand_num = rand_u64_range(1);

        if (raffle_type == 1) {
            let raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
            let nft_raffle = table::borrow_mut(&mut raffle_manager.nft_v1_raffles, raffle_id);
            assert!(!nft_raffle.active, E_RAFFLE_NOT_ENDED);
            let num_participants = smart_vector::length(&nft_raffle.participants);
            let winner = smart_vector::borrow(&nft_raffle.participants, rand_num % num_participants);
            let token_id = tokenv1::get_token_id(&nft_raffle.nft);
            token_transfers::offer(&resource_account::get_signer(), *winner, token_id, 1);
            // smart_vector::clear(&mut nft_raffle.participants);
            nft_raffle.active = false;
        } else if (raffle_type == 2) {
            let raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
            let nft_v2_raffle = table::borrow_mut(&mut raffle_manager.nft_v2_raffles, raffle_id);
             assert!(!nft_v2_raffle.active, E_RAFFLE_NOT_ENDED);
            let num_participants = smart_vector::length(&nft_v2_raffle.participants);
            let winner = smart_vector::borrow(&nft_v2_raffle.participants, rand_num % num_participants);
            object::transfer(admin, nft_v2_raffle.nft, *winner);
            // smart_vector::clear(&mut nft_v2_raffle.participants);
            nft_v2_raffle.active = false;
        } else {
            abort E_ERROR_INVALID_TYPE
        }
    }

    public entry fun toggle_coin_raffle<X>(admin: &signer, raffle_id: u64) acquires CoinRaffleManager {
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        let coin_raffle_manager = borrow_global_mut<CoinRaffleManager<X>>(resource_account::get_address());
        let coin_raffle = table::borrow_mut(&mut coin_raffle_manager.coin_raffles, raffle_id);
        coin_raffle.active = !coin_raffle.active;
    }

    public entry fun toggle_nft_raffle(admin: &signer, raffle_type: u64, raffle_id: u64)
    acquires NftRaffleManager {
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);

        let raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
        if (raffle_type == 1) {
            let nft_raffle = table::borrow_mut(&mut raffle_manager.nft_v1_raffles, raffle_id);
            nft_raffle.active = !nft_raffle.active;
        } else if (raffle_type == 2) {
            let nft_v2_raffle = table::borrow_mut(&mut raffle_manager.nft_v2_raffles, raffle_id);
            nft_v2_raffle.active = !nft_v2_raffle.active;
        } else {
            abort E_ERROR_INVALID_TYPE
        }
    } 

    public entry fun toggle_global_state(sender: &signer) acquires RaffleManager {
        assert!(signer::address_of(sender) == @nft, E_ERROR_UNAUTHORIZED);
        let raffle_manager = borrow_global_mut<RaffleManager>(resource_account::get_address());
        raffle_manager.global_active = !raffle_manager.global_active;
    }

    public entry fun add_coin_to_existing_coin_raffle<X>(admin: &signer, raffle_id: u64, coin_amount: u64)
    acquires CoinRaffleManager {
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        // assert!(check_status(), E_ERROR_RAFFLE_PAUSED);
        let coin_raffle_manager = borrow_global_mut<CoinRaffleManager<X>>(resource_account::get_address());
        let coin_raffle = table::borrow_mut(&mut coin_raffle_manager.coin_raffles, raffle_id);
        coin::merge(&mut coin_raffle.coin, coin::withdraw<X>(admin, coin_amount));
    }


    // ======================== View functions ========================
    #[view]
    public fun get_raffle_config<X>(
        raffle_type: u64,
        raffle_id: u64,
    ) : (u64, u64, bool) acquires CoinRaffleManager, NftRaffleManager {
        // assert!(check_status(), E_ERROR_RAFFLE_PAUSED);
        let (num_prize, participants, is_active) = if (raffle_type == 0) {
            let raffle_manager = borrow_global_mut<CoinRaffleManager<X>>(resource_account::get_address());
            let raffle = table::borrow(&mut raffle_manager.coin_raffles, raffle_id);
            let num_coins = coin::value<X>(&raffle.coin);
            (num_coins,&raffle.participants, raffle.active)
        } else if (raffle_type == 1) {
            let raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
            let raffle = table::borrow(&mut raffle_manager.nft_v1_raffles, raffle_id);
            (1, &raffle.participants, raffle.active)
        } else if (raffle_type ==2) {
            let raffle_manager = borrow_global_mut<NftRaffleManager>(resource_account::get_address());
            let raffle = table::borrow(&mut raffle_manager.nft_v2_raffles, raffle_id);
            (1, &raffle.participants, raffle.active)
        } else {
            abort E_ERROR_INVALID_TYPE
        };

        (num_prize, smart_vector::length(participants), is_active)
    }

    // ======================== Private functions ========================

    fun init_module(admin: &signer) {
        assert!(signer::address_of(admin) == @nft, E_ERROR_UNAUTHORIZED);
        move_to(&resource_account::get_signer(), RaffleManager {
            tickets: table::new<address, u64>(),
            global_active: true,
        });
        move_to(&resource_account::get_signer(), NftRaffleManager {
            nft_v1_raffles: table::new<u64, NFTRaffle>(),
            nft_v2_raffles: table::new<u64, NFTV2Raffle>(),
            nft_v1_raffle_count: 0,
            nft_v2_raffle_count: 0,
        });
    }


    fun emit_ticket_mint_event(user_address: address, ticket_amount: u64) {
        0x1::event::emit(TicketMintEvent {
            user_address,
            ticket_amount,
            timestamp: timestamp::now_microseconds(),
        });
    }

    fun emit_raffle_entry_event(coin_type: String, raffle_type: u64, raffle_id: u64, tickets_used: u64, user: address) {
        0x1::event::emit(RaffleEntryEvent {
            coin_type,
            raffle_type,
            raffle_id,
            tickets_used,
            user,
        });
    }

    fun check_caller_address(caller: address): bool {
        let resource_address = resource_account::get_address();
        let allowed_addresses: vector<address> = vector[ @nft, @ticketminter, resource_address];
        vector::contains(&allowed_addresses, &caller)
    }


    fun rand_u64_range(i: u64): u64 {
        let tx_hash = transaction_context::get_transaction_hash();
        let timestamp = bcs::to_bytes(&timestamp::now_microseconds());
        let i_bytes = bcs::to_bytes<u64>(&i);

        let seed = tx_hash;
        vector::append(&mut seed, timestamp);
        vector::append(&mut seed, i_bytes);
        let hash = hash::sha3_256(seed);
        let value = bytes_to_u64(hash);
        value
    }

    fun bytes_to_u64(bytes: vector<u8>): u64 {
        let value = 0u64;
        let i = 0u64;
        while (i < 8) {
            value = value | ((*vector::borrow(&bytes, i) as u64) << ((8 * (7 - i)) as u8));
            i = i + 1;
        };
        return value
    }

    fun check_status(): bool acquires RaffleManager {
        let raffle_manager = borrow_global<RaffleManager>(resource_account::get_address());
        raffle_manager.global_active
    }


}