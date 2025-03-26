// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FunctionsClient} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

contract FearAndGreedIndexConsumer is FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;

    address router = 0x234a5fb5Bd614a7AA2FfAB244D603abFA0Ac5C5C;
    bytes32 donID =  // abritrum sepolia
        0x66756e2d617262697472756d2d7365706f6c69612d3100000000000000000000;
    uint32 gasLimit = 300000;
    uint256 public index;
    uint24 constant SUBSCRIPTION_ID = 345;

    //add a block.timestamp state so the api only gets called once a day when FnG index update on site

    event Response(
        bytes32 indexed requestId,
        uint256 value,
        bytes response,
        bytes err
    );

    error UnexpectedRequestID(bytes32 requestId);

    string source =
        "const apiResponse = await Functions.makeHttpRequest({"
        "'url': 'https://pro-api.coinmarketcap.com/v3/fear-and-greed/latest',"
        "'headers': {'X-CMC_PRO_API_KEY': ''}"
        "});"
        "if(apiResponse.error) throw Error('Request failed');"
        "return Functions.encodeString(apiResponse.data.data.value);";

    constructor() FunctionsClient(router)  {}

    function sendRequest() internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);

        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            SUBSCRIPTION_ID,
            gasLimit,
            donID
        );

        return s_lastRequestId;
    }

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (s_lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId);
        }

        s_lastResponse = response;
        index = stringToUint(string(response));
        s_lastError = err;

        emit Response(requestId, index, s_lastResponse, s_lastError);
    }

    function stringToUint(string memory s) internal pure returns (uint) {
        bytes memory b = bytes(s);
        uint result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint256 c = uint256(uint8(b[i]));
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        return result;
    }
}