// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleBody} from "../src/OracleBody.sol";

contract OracleBodyHarness {
    function validate(bytes calldata body) external pure returns (uint16, uint16) {
        return OracleBody.validate(body);
    }

    function title(string calldata t) external pure {
        OracleBody.validateTitle(t);
    }
}

contract OracleBodyTest is Test {
    OracleBodyHarness harness;
    string constant BASE =
        '{"v":1,"question":"Did the event happen?","chainId":1,"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":900}';

    function setUp() public {
        harness = new OracleBodyHarness();
    }

    function test_validRelativeAbsoluteWhitespaceEscapesAndUnicode() public view {
        (uint16 panel, uint16 quorum) = harness.validate(bytes(BASE));
        assertEq(panel, 5);
        assertEq(quorum, 4);
        harness.validate(bytes(_replace(BASE, '"hours":24', '"fromBlock":100,"toBlock":200')));
        harness.validate(bytes(string.concat(" \n\t", BASE, "\r ")));
        harness.validate(bytes(_replace(BASE, "Did the event happen?", unicode"Did the event happen? ⚖️")));
        harness.validate(
            bytes(_replace(BASE, "Did the event happen?", 'quote \\" slash \\\\ newline \\n emoji \\uD83D\\uDE00'))
        );
        harness.validate(
            bytes(
                _replace(
                    BASE,
                    '"validForSeconds":900',
                    '"validForSeconds":900,"definitions":{"event":"Definition"},"allowAmbiguous":false'
                )
            )
        );
        harness.validate(
            bytes(
                _replace(BASE, '"validForSeconds":900', '"validForSeconds":900,"definitions":{},"allowAmbiguous":true')
            )
        );
        harness.title(unicode"A courtroom ⚖️");
    }

    function test_rejectsRedirectsUnknownAndDuplicateKeys() public {
        _bad(_replace(BASE, '"v":1', '"v":1,"consumer":"attacker"'));
        _bad(_replace(BASE, '"v":1', '"v":1,"deliver":{}'));
        _bad(_replace(BASE, '"v":1', '"v":1,"extra":true'));
        _bad(_replace(BASE, '"v":1', '"v":1,"v":1'));
        _bad(_replace(BASE, '"question"', '"qu\\u0065stion"'));
        _bad(_replace(BASE, '"validForSeconds":900', '"validForSeconds":900,"definitions":{"same":"a","same":"b"}'));
        _bad(_replace(BASE, '"validForSeconds":900', '"validForSeconds":900,"definitions":{"s\\u0061me":"a"}'));
    }

    function test_requiresBooleanPanelEthereumAndCompleteSchema() public {
        _bad(_replace(BASE, '"bool"', '"uint256"'));
        _bad(_replace(BASE, '"panel"', '"chain"'));
        _bad(_replace(BASE, '"chainId":1', '"chainId":4663'));
        _bad(_replace(BASE, '"v":1', '"v":2'));
        _bad(_replace(BASE, '"question":"Did the event happen?",', ""));
        _bad(_replace(BASE, "Did the event happen?", ""));
        _bad(_replace(BASE, '"quorum":4', '"quorum":0'));
        _bad(_replace(BASE, '"panelSize":5', '"panelSize":4'));
        _bad(_replace(BASE, '"panelSize":5', '"panelSize":101'));
        _bad(_replace(BASE, '"quorum":4', '"quorum":6'));
        _bad(_replace(BASE, '"validForSeconds":900', '"validForSeconds":59'));
        _bad(_replace(BASE, '"validForSeconds":900', '"validForSeconds":2592001'));
    }

    function test_windowValidation() public {
        _bad(_replace(BASE, '"hours":24', '"hours":0'));
        _bad(_replace(BASE, '"hours":24', '"hours":721'));
        _bad(_replace(BASE, '"hours":24', '"hours":24,"hours":24'));
        _bad(_replace(BASE, '"hours":24', '"fromBlock":200,"toBlock":100'));
        _bad(_replace(BASE, '"hours":24', '"fromBlock":100'));
        _bad(_replace(BASE, '"hours":24', '"fromBlock":100,"toBlock":200,"hours":24'));
        _bad(_replace(BASE, '"hours":24', '"fromBlock":100,"toBlock":18446744073709551616'));
        _bad(_replace(BASE, '"hours":24', '"hours":24,'));
    }

    function test_rejectsBrokenJsonNonIntegerNumbersAndTrailingData() public {
        _bad("");
        _bad("{}");
        _bad(string.concat(BASE, "{}"));
        _bad(_replace(BASE, '"v":1', '"v":01'));
        _bad(_replace(BASE, '"v":1', '"v":1.0'));
        _bad(_replace(BASE, '"v":1', '"v":1e0'));
        _bad(_replace(BASE, '"v":1', '"v":-1'));
        _bad(_replace(BASE, '"v":1', '"v":true'));
        _bad(
            _replace(
                BASE, '"v":1', '"v":115792089237316195423570985008687907853269984665640564039457584007913129639936'
            )
        );
        _bad(_replace(BASE, '"question":"Did the event happen?"', '"question":null'));
        _bad(_replace(BASE, '"validForSeconds":900}', '"validForSeconds":900,}'));
        _bad(_replace(BASE, "Did the event happen?", "unfinished \\"));
        _bad(_replace(BASE, "Did the event happen?", "bad \\q"));
        _bad(_replace(BASE, "Did the event happen?", "bad \\uZZZZ"));
        _bad(_replace(BASE, "Did the event happen?", "bad \\uD800"));
        _bad(_replace(BASE, "Did the event happen?", "bad \\uDC00"));
        _bad(_replace(BASE, "Did the event happen?", "bad \\uD800\\u0041"));
        _bad(_replace(BASE, '"validForSeconds":900', '"validForSeconds":900,"allowAmbiguous":null'));
    }

    function test_rejectsInvalidUtf8AndControlCharacters() public {
        _bad(_replace(BASE, "Did the event happen?", string(bytes(hex"c080"))));
        _bad(_replace(BASE, "Did the event happen?", string(bytes(hex"eda080"))));
        _bad(_replace(BASE, "Did the event happen?", string(bytes(hex"f4908080"))));
        _bad(_replace(BASE, "Did the event happen?", string(bytes(hex"e282"))));
        _bad(_replace(BASE, "Did the event happen?", string(bytes(hex"00"))));
        _bad(_replace(BASE, "Did the event happen?", string(bytes(hex"f5808080"))));
        _bad(_replace(BASE, "Did the event happen?", string(bytes(hex"e228a1"))));
    }

    function test_lengthLimitsAndDefinitionShape() public {
        bytes memory long = new bytes(2001);
        for (uint256 i; i < long.length; ++i) {
            long[i] = "a";
        }
        _bad(_replace(BASE, "Did the event happen?", string(long)));
        _bad(_replace(BASE, '"validForSeconds":900', '"validForSeconds":900,"definitions":{"event":true}'));
        _bad(
            _replace(
                BASE,
                '"validForSeconds":900',
                string.concat('"validForSeconds":900,"definitions":{"event":"', string(long), '"}')
            )
        );
        _bad(_replace(BASE, '"validForSeconds":900', '"validForSeconds":900,"definitions":{"":"a"}'));
        bytes memory huge = new bytes(16_385);
        vm.expectRevert(OracleBody.InvalidOracleBody.selector);
        harness.validate(huge);
        vm.expectRevert(OracleBody.InvalidOracleBody.selector);
        harness.title("");
        vm.expectRevert(OracleBody.InvalidOracleBody.selector);
        harness.title(string(long));
        vm.expectRevert(OracleBody.InvalidOracleBody.selector);
        harness.title("newline\n");
        vm.expectRevert(OracleBody.InvalidOracleBody.selector);
        harness.title(string(bytes(hex"c080")));
    }

    function testFuzz_arbitraryInputNeverPanics(bytes memory body) public view {
        (bool ok, bytes memory result) = address(harness).staticcall(abi.encodeCall(harness.validate, (body)));
        if (!ok) {
            assertEq(result.length, 4);
            assertEq(bytes4(result), OracleBody.InvalidOracleBody.selector);
        }
    }

    function testFuzz_acceptsBoundedAsciiQuestions(bytes memory text) public view {
        uint256 length = text.length == 0 ? 1 : text.length;
        if (length > 2000) length = 2000;
        bytes memory question = new bytes(length);
        for (uint256 i; i < length; ++i) {
            question[i] = bytes1(uint8(65 + (text.length == 0 ? 0 : uint8(text[i]) % 26)));
        }
        harness.validate(bytes(_replace(BASE, "Did the event happen?", string(question))));
    }

    function testFuzz_mutationAndTruncationNeverPanic(uint256 offset, uint8 replacement, bool truncate) public view {
        bytes memory body = bytes(BASE);
        offset %= body.length;
        if (truncate) {
            bytes memory prefix = new bytes(offset);
            for (uint256 i; i < offset; ++i) {
                prefix[i] = body[i];
            }
            body = prefix;
        } else {
            body[offset] = bytes1(replacement);
        }
        (bool ok, bytes memory result) = address(harness).staticcall(abi.encodeCall(harness.validate, (body)));
        if (!ok) {
            assertEq(result.length, 4);
            assertEq(bytes4(result), OracleBody.InvalidOracleBody.selector);
        }
    }

    function _bad(string memory body) private {
        vm.expectRevert(OracleBody.InvalidOracleBody.selector);
        harness.validate(bytes(body));
    }

    function _replace(string memory original, string memory needle, string memory replacement)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(original);
        bytes memory n = bytes(needle);
        for (uint256 i; i + n.length <= b.length; ++i) {
            bool matches = true;
            for (uint256 j; j < n.length; ++j) {
                if (b[i + j] != n[j]) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;
            bytes memory before = new bytes(i);
            bytes memory after_ = new bytes(b.length - i - n.length);
            for (uint256 j; j < i; ++j) {
                before[j] = b[j];
            }
            for (uint256 j; j < after_.length; ++j) {
                after_[j] = b[i + n.length + j];
            }
            return string(bytes.concat(before, bytes(replacement), after_));
        }
        revert("needle not found");
    }
}
