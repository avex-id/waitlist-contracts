module mini_games::resource_account_manager {

    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::timestamp;
    use std::bcs;


    friend mini_games::nft_lottery;
    friend mini_games::raffle;
    friend mini_games::dice_roll;


    struct SignerCapabilityStore has key {
        signer_capability: SignerCapability
    }


    #[view]
    public(friend) fun get_address():
    address
    acquires SignerCapabilityStore {
        let signer_capability_ref =
            &borrow_global<SignerCapabilityStore>(@mini_games).signer_capability;
        account::get_signer_capability_address(signer_capability_ref)
    }

    public(friend) fun get_signer():
    signer
    acquires SignerCapabilityStore {
        let signer_capability_ref =
            &borrow_global<SignerCapabilityStore>(@mini_games).signer_capability;
        account::create_signer_with_capability(signer_capability_ref)
    }

   
    fun init_module(
        admin: &signer
    ) {
        let time_seed = bcs::to_bytes(&timestamp::now_microseconds());
        let (_, signer_capability) =
            account::create_resource_account(admin, time_seed);
        move_to(admin, SignerCapabilityStore{signer_capability});
    }

    #[test_only]
    struct TestStruct has key {}

    #[test_only]
    public fun init_test() {
        let aptos_framework = account::create_signer_with_capability(
            &account::create_test_signer_cap(@aptos_framework));
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let volt = account::create_signer_with_capability(
            &account::create_test_signer_cap(@volt));
        init_module(&volt); 
    }

    #[test]
    fun test_mixed()
    acquires SignerCapabilityStore {
        init_test();
        move_to<TestStruct>(&get_signer(), TestStruct{});
        assert!(exists<TestStruct>(get_address()), 0);
    }


}