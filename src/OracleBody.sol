// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Validates the supported same-chain, boolean/panel request schema.
/// @dev No string concatenation or interpretation of creator text. Only internal functions.
library OracleBody {
    error InvalidOracleBody();

    uint256 internal constant MAX_BODY = 16_384;

    function validate(bytes calldata body) internal pure returns (uint16 panel, uint16 quorum) {
        if (body.length == 0 || body.length > MAX_BODY) revert InvalidOracleBody();
        uint256 p = _expect(body, 0, "{");
        uint256 seen;
        while (true) {
            p = _space(body, p);
            if (p >= body.length) revert InvalidOracleBody();
            if (body[p] == "}") {
                ++p;
                break;
            }
            (uint256 start, uint256 end,, uint256 next) = _string(body, p);
            bytes32 key = keccak256(body[start:end]);
            p = _expect(body, next, ":");
            uint256 bit;
            uint256 number;
            if (key == keccak256("v")) {
                bit = 1;
                (number, p) = _uint(body, p);
                if (number != 1) revert InvalidOracleBody();
            } else if (key == keccak256("question")) {
                bit = 2;
                uint256 chars;
                (,, chars, p) = _string(body, _space(body, p));
                if (chars == 0 || chars > 2000) revert InvalidOracleBody();
            } else if (key == keccak256("chainId")) {
                bit = 4;
                (number, p) = _uint(body, p);
                if (number != 1) revert InvalidOracleBody();
            } else if (key == keccak256("window")) {
                bit = 8;
                p = _window(body, p);
            } else if (key == keccak256("answerType")) {
                bit = 16;
                p = _literalString(body, p, keccak256("bool"));
            } else if (key == keccak256("evidence")) {
                bit = 32;
                p = _literalString(body, p, keccak256("panel"));
            } else if (key == keccak256("panelSize")) {
                bit = 64;
                (number, p) = _uint(body, p);
                if (number < 5 || number > 100) revert InvalidOracleBody();
                panel = uint16(number);
            } else if (key == keccak256("quorum")) {
                bit = 128;
                (number, p) = _uint(body, p);
                if (number < 4 || number > 100) revert InvalidOracleBody();
                quorum = uint16(number);
            } else if (key == keccak256("validForSeconds")) {
                bit = 256;
                (number, p) = _uint(body, p);
                if (number < 60 || number > 30 days) revert InvalidOracleBody();
            } else if (key == keccak256("definitions")) {
                bit = 512;
                p = _definitions(body, p);
            } else if (key == keccak256("allowAmbiguous")) {
                bit = 1024;
                p = _boolean(body, p);
            } else {
                // In particular, consumer and deliver cannot redirect this market's answer.
                revert InvalidOracleBody();
            }
            if (seen & bit != 0) revert InvalidOracleBody();
            seen |= bit;
            p = _space(body, p);
            if (p >= body.length) revert InvalidOracleBody();
            if (body[p] == "}") {
                ++p;
                break;
            }
            p = _expect(body, p, ",");
            if (_peek(body, p) == "}") revert InvalidOracleBody();
        }
        if (seen & 511 != 511 || quorum > panel || _space(body, p) != body.length) revert InvalidOracleBody();
    }

    function validateTitle(string calldata title) internal pure {
        bytes calldata b = bytes(title);
        if (b.length == 0 || b.length > 200) revert InvalidOracleBody();
        uint256 p;
        while (p < b.length) {
            if (uint8(b[p]) < 0x20) revert InvalidOracleBody();
            p = _utf8(b, p);
        }
    }

    function _window(bytes calldata b, uint256 p) private pure returns (uint256) {
        p = _expect(b, p, "{");
        uint256 seen;
        uint256 from;
        uint256 to;
        while (true) {
            (uint256 start, uint256 end,, uint256 next) = _string(b, _space(b, p));
            bytes32 key = keccak256(b[start:end]);
            uint256 n;
            (n, p) = _uint(b, _expect(b, next, ":"));
            uint256 bit;
            if (key == keccak256("hours")) {
                bit = 1;
                if (n == 0 || n > 720) revert InvalidOracleBody();
            } else if (key == keccak256("fromBlock")) {
                bit = 2;
                from = n;
            } else if (key == keccak256("toBlock")) {
                bit = 4;
                to = n;
            } else {
                revert InvalidOracleBody();
            }
            if (n > type(uint64).max || seen & bit != 0) revert InvalidOracleBody();
            seen |= bit;
            p = _space(b, p);
            if (_peek(b, p) == "}") {
                ++p;
                break;
            }
            p = _expect(b, p, ",");
        }
        if (seen != 1 && (seen != 6 || to < from)) revert InvalidOracleBody();
        return p;
    }

    function _definitions(bytes calldata b, uint256 p) private pure returns (uint256) {
        p = _expect(b, p, "{");
        bytes32[64] memory keys;
        uint256 count;
        if (_peek(b, p) == "}") return _space(b, p) + 1;
        while (true) {
            (uint256 start, uint256 end, uint256 chars, uint256 next) = _string(b, _space(b, p));
            if (chars == 0 || chars > 64 || count == 64) revert InvalidOracleBody();
            // Plain ASCII keys avoid equivalent escaped spellings bypassing duplicate checks.
            for (uint256 i = start; i < end; ++i) {
                if (uint8(b[i]) < 0x20 || uint8(b[i]) >= 0x7f || b[i] == "\\") revert InvalidOracleBody();
            }
            bytes32 key = keccak256(b[start:end]);
            for (uint256 i; i < count; ++i) {
                if (keys[i] == key) revert InvalidOracleBody();
            }
            keys[count++] = key;
            (,, chars, p) = _string(b, _space(b, _expect(b, next, ":")));
            if (chars > 512) revert InvalidOracleBody();
            p = _space(b, p);
            if (_peek(b, p) == "}") return p + 1;
            p = _expect(b, p, ",");
        }
        revert InvalidOracleBody();
    }

    function _literalString(bytes calldata b, uint256 p, bytes32 expected) private pure returns (uint256) {
        (uint256 start, uint256 end,, uint256 next) = _string(b, _space(b, p));
        if (keccak256(b[start:end]) != expected) revert InvalidOracleBody();
        return next;
    }

    function _boolean(bytes calldata b, uint256 p) private pure returns (uint256) {
        p = _space(b, p);
        if (p + 4 <= b.length && keccak256(b[p:p + 4]) == keccak256("true")) return p + 4;
        if (p + 5 <= b.length && keccak256(b[p:p + 5]) == keccak256("false")) return p + 5;
        revert InvalidOracleBody();
    }

    function _uint(bytes calldata b, uint256 p) private pure returns (uint256 n, uint256 next) {
        p = _space(b, p);
        uint256 start = p;
        while (p < b.length && b[p] >= "0" && b[p] <= "9") {
            uint256 digit = uint8(b[p]) - 48;
            if (n > (type(uint256).max - digit) / 10) revert InvalidOracleBody();
            n = n * 10 + digit;
            ++p;
        }
        if (p == start || (p - start > 1 && b[start] == "0")) revert InvalidOracleBody();
        return (n, p);
    }

    function _string(bytes calldata b, uint256 p)
        private
        pure
        returns (uint256 start, uint256 end, uint256 chars, uint256 next)
    {
        if (p >= b.length || b[p] != '"') revert InvalidOracleBody();
        start = ++p;
        while (p < b.length) {
            if (b[p] == '"') return (start, p, chars, p + 1);
            if (uint8(b[p]) < 0x20) revert InvalidOracleBody();
            if (b[p] == "\\") {
                if (++p >= b.length) revert InvalidOracleBody();
                bytes1 escape = b[p++];
                if (escape == "u") {
                    uint256 code = _hex4(b, p);
                    p += 4;
                    if (code >= 0xd800 && code <= 0xdbff) {
                        if (p + 6 > b.length || b[p] != "\\" || b[p + 1] != "u") revert InvalidOracleBody();
                        uint256 low = _hex4(b, p + 2);
                        if (low < 0xdc00 || low > 0xdfff) revert InvalidOracleBody();
                        p += 6;
                    } else if (code >= 0xdc00 && code <= 0xdfff) {
                        revert InvalidOracleBody();
                    }
                } else if (
                    escape != '"' && escape != "\\" && escape != "/" && escape != "b" && escape != "f" && escape != "n"
                        && escape != "r" && escape != "t"
                ) {
                    revert InvalidOracleBody();
                }
            } else {
                p = _utf8(b, p);
            }
            ++chars;
        }
        revert InvalidOracleBody();
    }

    function _hex4(bytes calldata b, uint256 p) private pure returns (uint256 code) {
        if (p + 4 > b.length) revert InvalidOracleBody();
        for (uint256 i; i < 4; ++i) {
            uint8 c = uint8(b[p + i]);
            uint256 n;
            if (c >= 48 && c <= 57) n = c - 48;
            else if (c >= 65 && c <= 70) n = c - 55;
            else if (c >= 97 && c <= 102) n = c - 87;
            else revert InvalidOracleBody();
            code = code * 16 + n;
        }
    }

    function _utf8(bytes calldata b, uint256 p) private pure returns (uint256) {
        uint8 first = uint8(b[p]);
        if (first < 0x80) return p + 1;
        uint256 size;
        uint256 code;
        if (first >= 0xc2 && first <= 0xdf) {
            size = 2;
            code = first & 0x1f;
        } else if (first >= 0xe0 && first <= 0xef) {
            size = 3;
            code = first & 0x0f;
        } else if (first >= 0xf0 && first <= 0xf4) {
            size = 4;
            code = first & 0x07;
        } else {
            revert InvalidOracleBody();
        }
        if (p + size > b.length) revert InvalidOracleBody();
        for (uint256 i = 1; i < size; ++i) {
            uint8 c = uint8(b[p + i]);
            if (c < 0x80 || c > 0xbf) revert InvalidOracleBody();
            code = (code << 6) | (c & 0x3f);
        }
        if (
            (size == 3 && code < 0x800) || (size == 4 && code < 0x10000) || code > 0x10ffff
                || (code >= 0xd800 && code <= 0xdfff)
        ) revert InvalidOracleBody();
        return p + size;
    }

    function _space(bytes calldata b, uint256 p) private pure returns (uint256) {
        while (p < b.length && (b[p] == " " || b[p] == "\t" || b[p] == "\r" || b[p] == "\n")) ++p;
        return p;
    }

    function _peek(bytes calldata b, uint256 p) private pure returns (bytes1) {
        p = _space(b, p);
        if (p >= b.length) revert InvalidOracleBody();
        return b[p];
    }

    function _expect(bytes calldata b, uint256 p, bytes1 c) private pure returns (uint256) {
        p = _space(b, p);
        if (p >= b.length || b[p] != c) revert InvalidOracleBody();
        return p + 1;
    }
}
