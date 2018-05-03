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

    function toInterestRate(r) {
        return Math.trunc(10000000/r);
    }

    async function createMortgage() {
        // To use the mortgage manager the borrower
        // should approve the MortgageManager contract to transfer his 
        // MANA and RCN tokens
        await rcn.approve(mortgageManager.address, 10**32, {from:accounts[0]})
        await mana.approve(mortgageManager.address, 10**32, {from:accounts[0]})

        // The borrower should have enought MANA to pay the initial deposit
        await mana.createTokens(accounts[0], 30 * 10 ** 18)
        
        // Create a land and create an order in the Decentraland Marketplace
        await land.assignNewParcel(50, 60, accounts[1])
        await land.setApprovalForAll(landMarket.address, true, {from:accounts[1]})
        let landId = await land.encodeTokenId(50, 60)
        await landMarket.createOrder(landId, 200 * 10**18, 10**30, {from:accounts[1]})

        let durationLoan = 6 * 30 * 24 * 60 * 60
        let closeTime = 5 * 30 * 24 * 60 * 60
        let expirationRequest = Math.floor(Date.now() / 1000) + 1 * 30 * 24 * 60 * 60

        // Create the loan on the RCN engine and save the id
        // the loan should be in MANA currency
        let loanReceipt = await rcnEngine.createLoan(
            kyberOracle.address, // Contract of the oracle
            accounts[0], // Borrower of the loan (caller of this method)
            manaCurrency, // Currency of the loan, MANA
            web3.toWei(190), // Requested 200 MANA to buy the land
            toInterestRate(20), // Punitory interest rate, 20% anual
            toInterestRate(30), // Punnitory interest rate, 30% anual
            durationLoan, // Duration of the loan, 6 months
            closeTime, // Borrower can pay the loan at 5 months
            expirationRequest, // Mortgage request expires in 1 month
            "Decentraland mortgage"
        )

        // Retrieve the loan signature
        let loanSignature = await rcnEngine.getLoanSignature(kyberOracle.address, accounts[0], accounts[0], manaCurrency, web3.toWei(190),
            toInterestRate(20), toInterestRate(30), durationLoan, closeTime, expirationRequest, "Decentraland mortgage")

        // Request a Mortgage
        let mortgageReceipt = await mortgageManager.requestMortgage(
            rcnEngine.address, // Address of the RCN Engine
            loanSignature, // Loan id already created in RCN, it should be denominated in MANA
            30 * 10 ** 18, // Send the deposit (?) from the borrower, it should be remaining needed to buy the land + 10%
            landId // Land id to buy, it has to be on sell on the Decentraland market
        )

        // Get the mortgage ID
        let mortgageId = mortgageReceipt["logs"][0]["args"]["_id"]
    }

    it("Should request a mortgage", createMortgage)

    it("It should cancel a mortgage", async() => {
        // Do all the process to create a mortgage
        // loan ID is 1 and mortgage ID is 0
        await createMortgage()

        // Cancel the mortgage request to retrieve the deposit
        await mortgageManager.cancelMortgage(0)

        // Borrower should have his MANA back
        assert.equal((await mana.balanceOf(accounts[0])).toNumber(), 30*10**18)
    })

    it("Test mortgage creation and payment", async() => {
        // Buy land and put it to sell
        await land.assignNewParcel(50, 60, accounts[1])
        await land.setApprovalForAll(landMarket.address, true, {from:accounts[1]})
        let landId = await land.encodeTokenId(50, 60)
        await landMarket.createOrder(landId, 200 * 10**18, 10**30, {from:accounts[1]})

        // Request a loan for the mortgage it should be index 0
        let loanReceipt = await rcnEngine.createLoan(kyberOracle.address, accounts[2], manaCurrency, 190*10**18, 100000000, 100000000, 86400, 0, 10**30, "Test mortgage", {from:accounts[2]});
        let loanId = loanReceipt["logs"][0]["args"]["_index"];

        // Authorize mortgage manager
        await rcn.approve(mortgageManager.address, 10**32, {from:accounts[2]})
        
        // Mint MANA and Request mortgage
        await mana.createTokens(accounts[2], 40*10**18);
        await mana.approve(mortgageManager.address, 40*10**18, {from:accounts[2]})
        await mortgageManager.requestMortgageId(rcnEngine.address, loanId, 40*10**18, landId, {from:accounts[2]});
        let cosignerData = await mortgageManager.getData(0);

        // Lend
        await rcn.createTokens(accounts[3], 300*10**18);
        await rcn.approve(rcnEngine.address, 10**32, {from:accounts[3]});
        await rcnEngine.lend(loanId, [], mortgageManager.address, cosignerData, {from:accounts[3]});

        // Check that the mortgage started
        assert.equal(await land.ownerOf(landId), mortgageManager.address);
        assert.equal(await mana.balanceOf(accounts[1]), 200*10**18);
        assert.equal(await mana.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcn.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcnEngine.getCosigner(loanId), mortgageManager.address)
        
        let mortgage = await mortgageManager.mortgages(0);
        assert.equal(mortgage[0], accounts[2], "Borrower address")
        assert.equal(mortgage[1], rcnEngine.address, "Engine address")
        assert.equal(mortgage[2].toNumber(), 1, "Loan ID should be 1")
        assert.equal(mortgage[3].toNumber(), 40*10**18, "Deposit is 40 MANA")
        assert.equal(mortgage[5].toNumber(), 200*10**18, "Check land cost")
        assert.equal(mortgage[6].toNumber(), 1, "Status should be Ongoing")

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
        await rcnEngine.pay(loanId, 500*10**18, accounts[2], [], {from:accounts[2]})
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