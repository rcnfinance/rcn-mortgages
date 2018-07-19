const TestToken = artifacts.require("./utils/test/TestToken.sol");
const DecentralandRegistry = artifacts.require("./utils/test/decentraland/LANDRegistry.sol");
const DecentralandProxy = artifacts.require("./utils/test/decentraland/LANDProxy.sol");
const NanoLoanEngine = artifacts.require("./utils/test/ripiocredit/NanoLoanEngine.sol");
// const KyberChanger = artifacts.require("./changers/KyberTokenExchanger.sol")
const DecentralandMarket = artifacts.require("./utils/test/decentraland/Marketplace.sol");
const MortgageManager = artifacts.require("./MortgageManager.sol");
const MortgageHelper = artifacts.require("./MortgageHelper.sol");

// Kyber network
const KyberMock = artifacts.require("./KyberMock.sol");
const KyberOracle = artifacts.require("./KyberOracle.sol");
const KyberProxy = artifacts.require("./KyberProxy.sol");

// Bancor network
const BancorNetwork = artifacts.require      ('./test/bancor/BancorNetwork.sol');
const ContractIds = artifacts.require        ('./test/bancor/ContractIds.sol');
const BancorConverter = artifacts.require    ('./test/bancor/converter/BancorConverter.sol');
const BancorFormula = artifacts.require      ('./test/bancor/converter/BancorFormula.sol');
const BancorGasPriceLimit = artifacts.require('./test/bancor/converter/BancorGasPriceLimit.sol');
const SmartToken = artifacts.require         ('./test/bancor/token/SmartToken.sol');
const TestERC20Token = artifacts.require     ('./test/bancor/token/TestERC20Token.sol');
const EtherToken = artifacts.require         ('./test/bancor/token/EtherToken.sol');
const ContractRegistry = artifacts.require   ('./test/bancor/utility/ContractRegistry.sol');
const ContractFeatures = artifacts.require   ('./test/bancor/utility/ContractFeatures.sol');

// Bancor proxy and oracle
const BancorProxy = artifacts.require("./test/rcn/proxies/BancorProxy.sol")
const BancorOracle = artifacts.require("./test/rcn/BancorOracle.sol")

const ConverterRamp = artifacts.require('./ConverterRamp.sol');

function toBytes32(source) {
    const rl = 64;
    source = source.toString().replace("0x", "");
    if (source.length < rl) {
        const diff = 64 - source.length;
        source = "0".repeat(diff) + source;
    }
    return "0x" + source;
}


contract('NanoLoanEngine', function(accounts) {
    const manaCurrency = "0x4d414e4100000000000000000000000000000000000000000000000000000000";

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
        // Deploy decentraland marketplace
        landMarket = await DecentralandMarket.new(mana.address, land.address);
        // Deploy mortgage manager
        mortgageManager = await MortgageManager.new(rcn.address, mana.address, land.address, landMarket.address);
        // Deploy ramp
        converterRamp = await ConverterRamp.new();

        // Deploy bancor
        const weight10Percent = 100000;
        const gasPrice = 10**32;

        signer = accounts[9]

        let contractRegistry = await ContractRegistry.new();
        let contractIds = await ContractIds.new();

        let contractFeatures = await ContractFeatures.new();
        let contractFeaturesId = await contractIds.CONTRACT_FEATURES.call();
        await contractRegistry.registerAddress(contractFeaturesId, contractFeatures.address);

        let gasPriceLimit = await BancorGasPriceLimit.new(gasPrice);
        let gasPriceLimitId = await contractIds.BANCOR_GAS_PRICE_LIMIT.call();
        await contractRegistry.registerAddress(gasPriceLimitId, gasPriceLimit.address);

        let formula = await BancorFormula.new();
        let formulaId = await contractIds.BANCOR_FORMULA.call();
        await contractRegistry.registerAddress(formulaId, formula.address);

        let bancorNetwork = await BancorNetwork.new(contractRegistry.address);
        let bancorNetworkId = await contractIds.BANCOR_NETWORK.call();
        await contractRegistry.registerAddress(bancorNetworkId, bancorNetwork.address);
        await bancorNetwork.setSignerAddress(signer);
        
        // converter RCN-MANA
        smartToken = await SmartToken.new('RCN MANA Token', 'RCNMANA', 18);
        await smartToken.issue(accounts[9], 6500000 * 10 **18);
        converter = await BancorConverter.new(smartToken.address, contractRegistry.address, 0, rcn.address, 250000);
        await converter.addConnector(mana.address, 250000, false);
        await smartToken.transferOwnership(converter.address);
        await converter.acceptTokenOwnership();
        await rcn.createTokens(converter.address, 2500000 * 10 **18)
        await mana.createTokens(converter.address, 6500000 * 10 **18)

        // Deploy bancor proxy
        const bancorProxy = await BancorProxy.new(0x0);
        await bancorProxy.setConverter(rcn.address, mana.address, converter.address);
        bancorConverter = bancorProxy

        // Deploy bancor oracle
        bancorOracle = await BancorOracle.new()
        await bancorOracle.setRcn(rcn.address)
        await bancorOracle.addCurrencyConverter("MANA", mana.address, converter.address)

        // Deploy kyber network
        kyberNetwork = await KyberMock.new(mana.address, rcn.address)
        await mana.createTokens(kyberNetwork.address, 1000000*10**18);
        await rcn.createTokens(kyberNetwork.address, 1000000*10**18);
        await kyberNetwork.setRateRM(1262385660474240000);
        await kyberNetwork.setRateMR(792150949832820000);
        
        // Deploy kyber proxy
        kyberProxy = await KyberProxy.new(kyberNetwork.address)

        // Deploy kyber oracle
        kyberOracle = await KyberOracle.new()
        await kyberOracle.setRcn(rcn.address)
        await kyberOracle.setKyber(kyberNetwork.address)
        await kyberOracle.addCurrencyLink("MANA", mana.address, 18)

        assert.equal(await kyberOracle.tickerToToken(manaCurrency), mana.address)
    })

    async function setKyber() {
        // Deploy mortgage creator
        mortgageHelper = await MortgageHelper.new(mortgageManager.address, rcnEngine.address, rcn.address, mana.address, landMarket.address, kyberOracle.address, kyberProxy.address, converterRamp.address)
        // Whitelist the mortgage creator
        await mortgageManager.setCreator(mortgageHelper.address, true);

        // Setup mortgage helper for payments
        await mortgageHelper.setMarginSpend(300)
    }

    async function setBancor() {
        // Deploy mortgage creator
        mortgageHelper = await MortgageHelper.new(mortgageManager.address, rcnEngine.address, rcn.address, mana.address, landMarket.address, bancorOracle.address, bancorConverter.address, converterRamp.address)
        // Whitelist the mortgage creator
        await mortgageManager.setCreator(mortgageHelper.address, true);

        // Setup mortgage helper for payments
        await mortgageHelper.setMarginSpend(300)
    }

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
        let loanIdentifier = await rcnEngine.buildIdentifier(kyberOracle.address, accounts[0], accounts[0], manaCurrency, web3.toWei(190),
            toInterestRate(20), toInterestRate(30), durationLoan, closeTime, expirationRequest, "Decentraland mortgage")

        // Request a Mortgage
        let mortgageReceipt = await mortgageManager.requestMortgage(
            rcnEngine.address, // Address of the RCN Engine
            loanIdentifier, // Loan id already created in RCN, it should be denominated in MANA
            30 * 10 ** 18, // Send the deposit (?) from the borrower, it should be remaining needed to buy the land + 10%
            landId, // Land id to buy, it has to be on sell on the Decentraland market
            kyberProxy.address
        )

        // Get the mortgage ID
        let mortgageId = mortgageReceipt["logs"][0]["args"]["_id"]
    }

    it("Create a loan in a single transaction Kyber", async() => {
        await setKyber();

        // To use the mortgage manager the borrower
        // should approve the MortgageManager contract to transfer his RCN
        await rcn.approve(mortgageManager.address, 10**32, {from:accounts[0]})

        // The borrower should approve the mortgage creator to move his MANA
        await mana.approve(mortgageHelper.address, 10**32, {from:accounts[0]})

        // The borrower should have enought MANA to pay the initial deposit
        await mana.createTokens(accounts[0], 30 * 10 ** 18)
        
        // Create a land and create an order in the Decentraland Marketplace
        await land.assignNewParcel(50, 60, accounts[1])
        await land.setApprovalForAll(landMarket.address, true, {from:accounts[1]})
        let landId = await land.encodeTokenId(50, 60)
        await landMarket.createOrder(landId, 200 * 10**18, 10**30, {from:accounts[1]})

        let loanDuration = 6 * 30 * 24 * 60 * 60
        let closeTime = 5 * 30 * 24 * 60 * 60
        let expirationRequest = Math.floor(Date.now() / 1000) + 1 * 30 * 24 * 60 * 60

        let loanParams = [
            web3.toWei(190), // Amount requested
            toInterestRate(20), // Anual interest
            toInterestRate(30), // Anual punnitory interest
            loanDuration, // Duration of the loan, in seconds
            closeTime, // Time when the payment of the loan starts
            expirationRequest // Expiration timestamp of the request
        ]

        let loanMetadata = "#mortgage #required-cosigner:" + mortgageManager.address

        // Retrieve the loan signature
        let loanIdentifier = await rcnEngine.buildIdentifier(
            kyberOracle.address, // Contract of the oracle
            accounts[0], // Borrower of the loan (caller of this method)
            mortgageHelper.address, // Creator of the loan, the mortgage creator
            manaCurrency, // Currency of the loan, MANA
            web3.toWei(190), // Request amount
            toInterestRate(20), // Interest rate, 20% anual
            toInterestRate(30), // Punnitory interest rate, 30% anual
            loanDuration, // Duration of the loan, 6 months
            closeTime, // Borrower can pay the loan at 5 months
            expirationRequest, // Mortgage request expires in 1 month
            loanMetadata  // Metadata
        )

        // Sign the loan
        let approveSignature = await web3.eth.sign(accounts[0], loanIdentifier).slice(2)
        
        let r = `0x${approveSignature.slice(0, 64)}`
        let s = `0x${approveSignature.slice(64, 128)}`
        let v = web3.toDecimal(approveSignature.slice(128, 130)) + 27

        // Request a Mortgage
        let mortgageReceipt = await mortgageHelper.requestMortgage(
            loanParams, // Configuration of the loan request
            loanMetadata, // Metadata of the loan
            landId, // Id of the loan to buy
            v, // Signature of the loan
            r, // Signature of the loan
            s  // Signature of the loan
        )

        // Get the mortgage and loan ID
        let mortgageId = mortgageReceipt["logs"][0]["args"]["mortgageId"]
        let loanId = mortgageReceipt["logs"][0]["args"]["loanId"]

        assert.equal(mortgageId, 1)
        assert.equal(loanId, 1)

        // Check the loan
        assert.equal(await rcnEngine.getBorrower(loanId), accounts[0])
        assert.equal(await rcnEngine.getOracle(loanId), kyberOracle.address)
        assert.equal(await rcnEngine.getCurrency(loanId), manaCurrency)
        assert.equal(await rcnEngine.getAmount(loanId), web3.toWei(190))
        assert.equal(await rcnEngine.getInterestRate(loanId), toInterestRate(20))
        assert.equal(await rcnEngine.getInterestRatePunitory(loanId), toInterestRate(30))
        assert.equal(await rcnEngine.getDuesIn(loanId), loanDuration)
        assert.equal(await rcnEngine.getExpirationRequest(loanId), expirationRequest)
        
        // Check the mortgage
        assert.equal(await mana.balanceOf(mortgageManager.address), web3.toWei(30))
        let mortgageParams = await mortgageManager.mortgages(mortgageId)
        assert.equal(mortgageParams[0], accounts[0]) // Owner
        assert.equal(mortgageParams[1], rcnEngine.address) // Engine
        assert.equal(mortgageParams[2], loanId.toNumber()) // Loan id
        assert.equal(mortgageParams[3], web3.toWei(30)) // MANA Deposit
        assert.equal(mortgageParams[4], landId.toNumber()) // Land id
        assert.equal(mortgageParams[5], web3.toWei(200)) // Land cost
        assert.equal(mortgageParams[6], 0) // Status of the mortgage
    })

    it("Create a loan in a single transaction Bancor", async() => {
        await setBancor();

        // To use the mortgage manager the borrower
        // should approve the MortgageManager contract to transfer his RCN
        await rcn.approve(mortgageManager.address, 10**32, {from:accounts[0]})

        // The borrower should approve the mortgage creator to move his MANA
        await mana.approve(mortgageHelper.address, 10**32, {from:accounts[0]})

        // The borrower should have enought MANA to pay the initial deposit
        await mana.createTokens(accounts[0], 30 * 10 ** 18)
        
        // Create a land and create an order in the Decentraland Marketplace
        await land.assignNewParcel(50, 60, accounts[1])
        await land.setApprovalForAll(landMarket.address, true, {from:accounts[1]})
        let landId = await land.encodeTokenId(50, 60)
        await landMarket.createOrder(landId, 200 * 10**18, 10**30, {from:accounts[1]})

        let loanDuration = 6 * 30 * 24 * 60 * 60
        let closeTime = 5 * 30 * 24 * 60 * 60
        let expirationRequest = Math.floor(Date.now() / 1000) + 1 * 30 * 24 * 60 * 60

        let loanParams = [
            web3.toWei(190), // Amount requested
            toInterestRate(20), // Anual interest
            toInterestRate(30), // Anual punnitory interest
            loanDuration, // Duration of the loan, in seconds
            closeTime, // Time when the payment of the loan starts
            expirationRequest // Expiration timestamp of the request
        ]

        let loanMetadata = "#mortgage #required-cosigner:" + mortgageManager.address

        // Retrieve the loan signature
        let loanIdentifier = await rcnEngine.buildIdentifier(
            bancorOracle.address, // Contract of the oracle
            accounts[0], // Borrower of the loan (caller of this method)
            mortgageHelper.address, // Creator of the loan, the mortgage creator
            manaCurrency, // Currency of the loan, MANA
            web3.toWei(190), // Request amount
            toInterestRate(20), // Interest rate, 20% anual
            toInterestRate(30), // Punnitory interest rate, 30% anual
            loanDuration, // Duration of the loan, 6 months
            closeTime, // Borrower can pay the loan at 5 months
            expirationRequest, // Mortgage request expires in 1 month
            loanMetadata  // Metadata
        )

        // Sign the loan
        let approveSignature = await web3.eth.sign(accounts[0], loanIdentifier).slice(2)
        
        let r = `0x${approveSignature.slice(0, 64)}`
        let s = `0x${approveSignature.slice(64, 128)}`
        let v = web3.toDecimal(approveSignature.slice(128, 130)) + 27

        // Request a Mortgage
        let mortgageReceipt = await mortgageHelper.requestMortgage(
            loanParams, // Configuration of the loan request
            loanMetadata, // Metadata of the loan
            landId, // Id of the loan to buy
            v, // Signature of the loan
            r, // Signature of the loan
            s  // Signature of the loan
        )

        // Get the mortgage and loan ID
        let mortgageId = mortgageReceipt["logs"][0]["args"]["mortgageId"]
        let loanId = mortgageReceipt["logs"][0]["args"]["loanId"]

        assert.equal(mortgageId, 1)
        assert.equal(loanId, 1)

        // Check the loan
        assert.equal(await rcnEngine.getBorrower(loanId), accounts[0])
        assert.equal(await rcnEngine.getOracle(loanId), bancorOracle.address)
        assert.equal(await rcnEngine.getCurrency(loanId), manaCurrency)
        assert.equal(await rcnEngine.getAmount(loanId), web3.toWei(190))
        assert.equal(await rcnEngine.getInterestRate(loanId), toInterestRate(20))
        assert.equal(await rcnEngine.getInterestRatePunitory(loanId), toInterestRate(30))
        assert.equal(await rcnEngine.getDuesIn(loanId), loanDuration)
        assert.equal(await rcnEngine.getExpirationRequest(loanId), expirationRequest)
        
        // Check the mortgage
        assert.equal(await mana.balanceOf(mortgageManager.address), web3.toWei(30))
        let mortgageParams = await mortgageManager.mortgages(mortgageId)
        assert.equal(mortgageParams[0], accounts[0]) // Owner
        assert.equal(mortgageParams[1], rcnEngine.address) // Engine
        assert.equal(mortgageParams[2], loanId.toNumber()) // Loan id
        assert.equal(mortgageParams[3], web3.toWei(30)) // MANA Deposit
        assert.equal(mortgageParams[4], landId.toNumber()) // Land id
        assert.equal(mortgageParams[5], web3.toWei(200)) // Land cost
        assert.equal(mortgageParams[6], 0) // Status of the mortgage
    })


    it("Should request a mortgage", createMortgage)

    it("It should cancel a mortgage", async() => {
        // Do all the process to create a mortgage
        // loan ID is 1 and mortgage ID is 0
        await createMortgage()

        // Cancel the mortgage request to retrieve the deposit
        await mortgageManager.cancelMortgage(1)

        // Borrower should have his MANA back
        assert.equal((await mana.balanceOf(accounts[0])).toNumber(), 30*10**18)
    })

    it("Test mortgage creation and payment with Bancor", async() => {
        await setBancor();

        // Buy land and put it to sell
        await land.assignNewParcel(50, 60, accounts[1])
        await land.setApprovalForAll(landMarket.address, true, {from:accounts[1]})
        let landId = await land.encodeTokenId(50, 60)
        await landMarket.createOrder(landId, 200 * 10**18, 10**30, {from:accounts[1]})

        // Request a loan for the mortgage it should be index 0
        let loanReceipt = await rcnEngine.createLoan(bancorOracle.address, accounts[2], manaCurrency, 190*10**18, 100000000, 100000000, 86400, 0, 10**30, "Test mortgage Bancor", {from:accounts[2]});
        let loanId = loanReceipt["logs"][0]["args"]["_index"];

        // Authorize mortgage manager
        await rcn.approve(mortgageManager.address, 10**32, {from:accounts[2]})

        // Mint MANA and Request mortgage
        await mana.createTokens(accounts[2], 40*10**18);
        await mana.approve(mortgageManager.address, 40*10**18, {from:accounts[2]})
        await mortgageManager.requestMortgageId(rcnEngine.address, loanId, 40*10**18, landId, bancorConverter.address, {from:accounts[2]});
        let cosignerData = await mortgageManager.getData(1);

        // Lendadd
        await rcn.createTokens(accounts[3], 10**32);
        await rcn.approve(rcnEngine.address, 10**32, {from:accounts[3]});
        await rcn.approve(bancorConverter.address, 1 * 10**18, {from:accounts[3]});
        // await bancorConverter.change(rcn.address, mana.address, 100, 1, {from:accounts[3]});

        await rcnEngine.lend(loanId, [], mortgageManager.address, cosignerData, {from:accounts[3]});

        // Check that the mortgage started
        assert.equal(await land.ownerOf(landId), mortgageManager.address);
        assert.equal(await mana.balanceOf(accounts[1]), 200*10**18);
        assert.equal(await mana.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcn.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcnEngine.getCosigner(loanId), mortgageManager.address)
        
        let mortgage = await mortgageManager.mortgages(1);
        assert.equal(mortgage[0], accounts[2], "Borrower address")
        assert.equal(mortgage[1], rcnEngine.address, "Engine address")
        assert.equal(mortgage[2].toNumber(), 1, "Loan ID should be 1")
        assert.equal(mortgage[3].toNumber(), 40*10**18, "Deposit is 40 MANA")
        assert.equal(mortgage[5].toNumber(), 200*10**18, "Check land cost")
        assert.equal(mortgage[6].toNumber(), 1, "Status should be Ongoing")

        // Also test the ERC-721
        assert.equal(await mortgageManager.balanceOf(accounts[2]), 1)
        assert.equal(await mortgageManager.totalSupply(), 1)

        // Try to claim the mortgage witout default or payment
        await assertThrow(mortgageManager.claim(rcnEngine.address, 0, [], {from:accounts[2]})) // As borrower
        await assertThrow(mortgageManager.claim(rcnEngine.address, 0, [], {from:accounts[3]})) // As lender

        // Pay the loan and claim the mortgage
        await rcn.createTokens(accounts[2], 300*10**18)
        await rcn.approve(rcnEngine.address, 10**32, {from:accounts[2]})
        await rcnEngine.pay(loanId, 500*10**18, accounts[2], [], {from:accounts[2]})
        await mortgageManager.claim(rcnEngine.address, 1, [], {from:accounts[2]})

        // Check the mortgage status
        mortgage = await mortgageManager.mortgages(1);
        assert.equal(await land.ownerOf(landId), accounts[2])
        assert.equal(mortgage[6].toNumber(), 3, "Status should be Paid")

        // Also test the ERC-721
        assert.equal(await mortgageManager.balanceOf(accounts[2]), 0)
        assert.equal(await mortgageManager.totalSupply(), 0)
    })

    it("Should be payable from the mortgage helper", async() => {
        await setBancor();

        // Buy land and put it to sell
        await land.assignNewParcel(50, 60, accounts[1])
        await land.setApprovalForAll(landMarket.address, true, {from:accounts[1]})
        let landId = await land.encodeTokenId(50, 60)
        await landMarket.createOrder(landId, 200 * 10**18, 10**30, {from:accounts[1]})

        // Request a loan for the mortgage it should be index 0
        let loanReceipt = await rcnEngine.createLoan(bancorOracle.address, accounts[2], manaCurrency, 190*10**18, 100000000, 100000000, 86400, 0, 10**30, "Test mortgage Bancor", {from:accounts[2]});
        let loanId = loanReceipt["logs"][0]["args"]["_index"];

        // Authorize mortgage manager
        await rcn.approve(mortgageManager.address, 10**32, {from:accounts[2]})
        
        // Mint MANA and Request mortgage
        await mana.createTokens(accounts[2], 40*10**18);
        await mana.approve(mortgageManager.address, 40*10**18, {from:accounts[2]})
        await mortgageManager.requestMortgageId(rcnEngine.address, loanId, 40*10**18, landId, bancorConverter.address, {from:accounts[2]});
        let cosignerData = await mortgageManager.getData(1);

        // Lendadd
        await rcn.createTokens(accounts[3], 10**32);
        await rcn.approve(rcnEngine.address, 10**32, {from:accounts[3]});
        await rcn.approve(bancorConverter.address, 1 * 10**18, {from:accounts[3]});

        await rcnEngine.lend(loanId, [], mortgageManager.address, cosignerData, {from:accounts[3]});

        // Check that the mortgage started
        assert.equal(await land.ownerOf(landId), mortgageManager.address);
        assert.equal(await mana.balanceOf(accounts[1]), 200*10**18);
        assert.equal(await mana.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcn.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcnEngine.getCosigner(loanId), mortgageManager.address)
        
        let mortgage = await mortgageManager.mortgages(1);
        assert.equal(mortgage[0], accounts[2], "Borrower address")
        assert.equal(mortgage[1], rcnEngine.address, "Engine address")
        assert.equal(mortgage[2].toNumber(), 1, "Loan ID should be 1")
        assert.equal(mortgage[3].toNumber(), 40*10**18, "Deposit is 40 MANA")
        assert.equal(mortgage[5].toNumber(), 200*10**18, "Check land cost")
        assert.equal(mortgage[6].toNumber(), 1, "Status should be Ongoing")

        // Also test the ERC-721
        assert.equal(await mortgageManager.balanceOf(accounts[2]), 1)
        assert.equal(await mortgageManager.totalSupply(), 1)

        // Try to claim the mortgage witout default or payment
        await assertThrow(mortgageManager.claim(rcnEngine.address, 0, [], {from:accounts[2]})) // As borrower
        await assertThrow(mortgageManager.claim(rcnEngine.address, 0, [], {from:accounts[3]})) // As lender

        // Perform a partial payment
        await mana.createTokens(accounts[2], 101*10**18)
        await mana.approve(mortgageHelper.address, 101*10**18, {from:accounts[2]})
        await mortgageHelper.pay(rcnEngine.address, loanId, 100*10**18, {from:accounts[2]})
        
        assert.isAtLeast(parseInt(await rcnEngine.getPaid(loanId)), 100 * 10 ** 18);
    })

    it("Test mortgage creation and payment", async() => {
        await setKyber();

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
        await mortgageManager.requestMortgageId(rcnEngine.address, loanId, 40*10**18, landId, kyberProxy.address, {from:accounts[2]});
        let cosignerData = await mortgageManager.getData(1);
 
        // Lend
        await rcn.createTokens(accounts[3], 151*10**18);
        await rcn.approve(rcnEngine.address, 151 * 10**18, {from:accounts[3]});
        await rcnEngine.lend(loanId, [], mortgageManager.address, cosignerData, {from:accounts[3]});
        // await rcnEngine.lend(loanId, [], 0x0, [], {from:accounts[3]});

        // Check that the mortgage started
        assert.equal(await land.ownerOf(landId), mortgageManager.address);
        assert.equal(await mana.balanceOf(accounts[1]), 200*10**18);
        assert.equal(await mana.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcn.balanceOf(mortgageManager.address), 0)
        assert.equal(await rcnEngine.getCosigner(loanId), mortgageManager.address)
        
        let mortgage = await mortgageManager.mortgages(1);
        assert.equal(mortgage[0], accounts[2], "Borrower address")
        assert.equal(mortgage[1], rcnEngine.address, "Engine address")
        assert.equal(mortgage[2].toNumber(), 1, "Loan ID should be 1")
        assert.equal(mortgage[3].toNumber(), 40*10**18, "Deposit is 40 MANA")
        assert.equal(mortgage[5].toNumber(), 200*10**18, "Check land cost")
        assert.equal(mortgage[6].toNumber(), 1, "Status should be Ongoing")

        // Also test the ERC-721
        assert.equal(await mortgageManager.balanceOf(accounts[2]), 1)
        assert.equal(await mortgageManager.totalSupply(), 1)

        // Try to claim the mortgage witout default or payment
        await assertThrow(mortgageManager.claim(rcnEngine.address, 1, [], {from:accounts[2]})) // As borrower
        await assertThrow(mortgageManager.claim(rcnEngine.address, 1, [], {from:accounts[3]})) // As lender

        // Pay the loan and claim the mortgage
        await rcn.createTokens(accounts[2], 300*10**18)
        await rcn.approve(rcnEngine.address, 10**32, {from:accounts[2]})
        await rcnEngine.pay(loanId, 500*10**18, accounts[2], [], {from:accounts[2]})
        await mortgageManager.claim(rcnEngine.address, loanId, [], {from:accounts[2]})

        // Check the mortgage status
        mortgage = await mortgageManager.mortgages(1);
        assert.equal(await land.ownerOf(landId), accounts[2])
        assert.equal(mortgage[6].toNumber(), 3, "Status should be Paid")

        // Also test the ERC-721
        assert.equal(await mortgageManager.balanceOf(accounts[2]), 0)
        assert.equal(await mortgageManager.totalSupply(), 0)
    })
})