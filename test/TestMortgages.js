var TestToken = artifacts.require("./utils/test/TestToken.sol");
var DecentralandRegistry = artifacts.require("./utils/test/decentraland/LANDRegistry.sol");
var DecentralandProxy = artifacts.require("./utils/test/decentraland/LANDProxy.sol");
var NanoLoanEngine = artifacts.require("./utils/test/ripiocredit/NanoLoanEngine.sol");
var KyberMock = artifacts.require("./KyberMock.sol");
var KyberOracle = artifacts.require("./KyberOracle.sol");

contract('NanoLoanEngine', function(accounts) {
    let land;
    let rcnEngine;
    let rcn;
    let mana;
    let kyberOracle;
    let kyber;

    beforeEach("Deploy Tokens, Land, Market, Kyber", async function(){
        // Deploy decentraland
        let landRegistry = await DecentralandRegistry.new();
        land = await DecentralandProxy.new();
        await land.upgrade(landRegistry.address, []);
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
        // TODO: Set rates
        // Deploy kyber oracle
        kyberOracle = await KyberOracle.new();
        await kyberOracle.addCurrency("MANA", mana.address, 18);
        await kyberOracle.setRcn(rcn.address);
        await kyberOracle.setKyber(kyber.address);
    })
})