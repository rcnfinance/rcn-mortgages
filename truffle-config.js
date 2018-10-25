module.exports = {
    networks: {
          test: {
              host: 'localhost',
              port: 8545,
              network_id: '*', // Match any network id,
              gas: 47123880,
              gasPrice: 65000000000,
          },
      },
      solc: {
          optimizer: {
              enabled: true,
              runs: 200,
          },
      }
  }
  