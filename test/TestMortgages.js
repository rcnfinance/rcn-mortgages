var TestToken = artifacts.require("./utils/test/TestToken.sol");
var DecentralandRegistry = artifacts.require("./utils/test/decentraland/LANDRegistry.sol");
var DecentralandProxy = artifacts.require("./utils/test/decentraland/LANDProxy.sol");
var NanoLoanEngine = artifacts.require("./utils/test/ripiocredit/NanoLoanEngine.sol");
var KyberMock = artifacts.require("./KyberMock.sol");
var KyberOracle = artifacts.require("./KyberOracle.sol");
var DecentralandMarket = artifacts.require("./utils/test/decentraland/Marketplace.sol");
var MortgageManager = artifacts.require("./MortgageManager.sol");

contract('NanoLoanEngine', function(accounts) {
    let manaCurrency;
    let land;
    let rcnEngine;
    let rcn;
    let mana;
    let kyberOracle;
    let kyber;
    let landMarket;
    let mortgageManager;

    async function assertThrow(promise) {
        try {
          await promise;
        } catch (error) {
          const invalidJump = error.message.search('invalid JUMP') >= 0;
          const revert = error.message.search('revert') >= 0;
          const invalidOpcode = error.message.search('invalid opcode') >0;
          const outOfGas = error.message.search('out of gas') >= 0;
          assert(
            invalidJump || outOfGas || revert || invalidOpcode,
            "Expected throw, got '" + error + "' instead",
          );
          return;
        }
        assert.fail('Expected throw not received');
    };

    beforeEach("Deploy Tokens, Land, Market, Kyber", async function(){
        // Deploy decentraland
        let landRegistry = await DecentralandRegistry.new();
        land = await DecentralandProxy.new();
        await land.upgrade(landRegistry.address, []);
        land = DecentralandRegistry.at(land.address)
        // Deploy MANA token
        mana = await TestToken.new("Mana", "MANA", 18, "1.0", 6000);
        // Deploy RCN token
        rcn = await TestToken.new("Ripio Credit Network", "RCN", 18, "1.1", 4000);
        // Deploy RCN Engine
        rcnEngine = await NanoLoanEngine.new(rcn.address);
        // Deploy Kyber network and fund it
        kyber = await KyberMock.new(mana.address, rcn.address);
        await mana.createTokens(kyber.address, 1000000*10**18);
        await rcn.createTokens(kyber.address, 1000000*10**18);
        await kyber.setRateRM(1262385660474240000);
        await kyber.setRateMR(792150949832820000);
        // Deploy kyber oracle
        kyberOracle = await KyberOracle.new();
        await kyberOracle.addCurrency("MANA");
        manaCurrency = await kyberOracle.currencies(0); 
        await kyberOracle.changeToken("MANA", mana.address);
        await kyberOracle.changeDecimals("MANA", 18);
        await kyberOracle.setRcn(rcn.address);
        await kyberOracle.setKyber(kyber.address);
        // Deploy decentraland marketplace
        landMarket = await DecentralandMarket.new(mana.address, land.address);
        // Deploy mortgage manager
        mortgageManager = await MortgageManager.new(rcn.address, mana.address, land.address, landMarket.address, kyber.address);
    })

    it("Test mortgage creation and payment", async() => {
        // Buy land and put it to sell
        await land.assignNewParcel(50, 60, accounts[1])
        await land.setApprovalForAll(landMarket.address, true, {from:accounts[1]})
        let landId = await land.encodeTokenId(50, 60)
        await landMarket.createOrder(landId, 200 * 10**18, 10**30, {from:accounts[1]})

        // Request a loan for the mortgage it should be index 0
        await rcnEngine.createLoan(kyberOracle.address, accounts[2], manaCurrency, 190*10**18, 100000000, 100000000, 86400, 0, 10**30, "Test mortgage", {from:accounts[2]});
        
        // Authorize mortgage manager
        await rcn.approve(mortgageManager.address, 10**32, {from:accounts[2]})
        
        // Mint MANA and Request mortgage
        await mana.createTokens(accounts[2], 40*10**18);
        await mana.approve(mortgageManager.address, 40*10**18, {from:accounts[2]})
        await mortgageManager.requestMortgageBuy(rcnEngine.address, 0, 40*10**18, landId, {from:accounts[2]});
        let cosignerData = await mortgageManager.getData(0);

        // Lend
        await rcn.createTokens(accounts[3], 300*10**18);
        await rcn.approve(rcnEngine.address, 10**32, {from:accounts[3]});
        await rcnEngine.lend(0, [], mortgageManager.address, cosignerData, {from:accounts[3]});

        // Check that the mortgage started
        assert.equal(await land.ownerOf(landId), mortgageManager.address);
        assert.equal(await mana.balanceOf(accounts[1]), 200*10**18);
        assert.equal(await mana.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcn.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcnEngine.getCosigner(0), mortgageManager.address)
        
        let mortgage = await mortgageManager.mortgages(0);
        assert.equal(mortgage[0], accounts[2], "Borrower address")
        assert.equal(mortgage[1], rcnEngine.address, "Engine address")
        assert.equal(mortgage[2].toNumber(), 0, "Loan ID should be 0")
        assert.equal(mortgage[3].toNumber(), 40*10**18, "Deposit is 40 MANA")
        assert.equal(mortgage[5].toNumber(), 200*10**18, "Check land cost")
        assert.equal(mortgage[6].toNumber(), 1, "Status should be Ongoing")
        assert.equal(mortgage[7].toNumber(), 0, "Type should be Buy")

        // Also test the ERC-721
        assert.equal(await mortgageManager.balanceOf(accounts[2]), 1)
        assert.equal(await mortgageManager.totalSupply(), 1)
        // TODO More tests

        // Try to claim the mortgage witout default or payment
        await assertThrow(mortgageManager.claim(rcnEngine.address, 0, [], {from:accounts[2]})) // As borrower
        await assertThrow(mortgageManager.claim(rcnEngine.address, 0, [], {from:accounts[3]})) // As lender

        // Pay the loan and claim the mortgage
        await rcn.createTokens(accounts[2], 300*10**18)
        await rcn.approve(rcnEngine.address, 10**32, {from:accounts[2]})
        await rcnEngine.pay(0, 500*10**18, accounts[2], [], {from:accounts[2]})
        await mortgageManager.claim(rcnEngine.address, 0, [], {from:accounts[2]})

        // Check the mortgage status
        mortgage = await mortgageManager.mortgages(0);
        assert.equal(await land.ownerOf(landId), accounts[2])
        assert.equal(mortgage[6].toNumber(), 3, "Status should be Paid")

        // Also test the ERC-721
        assert.equal(await mortgageManager.balanceOf(accounts[2]), 0)
        assert.equal(await mortgageManager.totalSupply(), 0)
        // TODO More tests
    })
})