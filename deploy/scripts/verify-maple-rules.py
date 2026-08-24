from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = "http://127.0.0.1:8000"
MID_POLISH = "\uc911\uae09 \uc5f0\ub9c8\uc81c"
TOP_POLISH = "\ucd5c\uace0\uae09 \uc5f0\ub9c8\uc81c"


def get_json(path: str):
    with urllib.request.urlopen(BASE_URL + path, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError(f"GET {path} returned {response.status}")
        return json.load(response)


def get_text(path: str) -> str:
    with urllib.request.urlopen(BASE_URL + path, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError(f"GET {path} returned {response.status}")
        return response.read().decode("utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    config = get_json("/api/config")
    rules = config.get("game_rules") or {}
    fees = rules.get("auction_fee_rates") or {}

    require(abs(float(fees.get("standard", -1)) - 0.05) < 1e-9, "standard auction fee must be 5%")
    require(abs(float(fees.get("pc_room_receive", -1)) - 0.03) < 1e-9, "PC-room receive fee must be 3%")
    require(abs(float(rules.get("guild_shop_discount_rate", -1)) - 0.04) < 1e-9, "guild shop discount must be 4%")
    require(abs(float(rules.get("pc_room_craft_success_bonus_max", -1)) - 0.10) < 1e-9, "PC-room craft success bonus ceiling must be 10%")

    fixed = get_json("/api/meister/fixed-shop-prices")
    require(isinstance(fixed, list) and len(fixed) >= 10, "fixed shop catalog is unexpectedly small")
    require(int(rules.get("fixed_shop_item_count", -1)) == len(fixed), "fixed shop count does not match config")

    by_name = {row.get("item_name"): row for row in fixed}
    mid = by_name.get(MID_POLISH)
    top = by_name.get(TOP_POLISH)
    require(mid is not None, "middle polishing agent is missing from fixed shop")
    require(top is not None, "top polishing agent is missing from fixed shop")
    require(int(mid.get("regular_price", -1)) == 5000, "middle polishing agent regular price must be 5000")
    require(int(mid.get("guild_price", -1)) == 4800, "middle polishing agent guild price must be 4800")
    require(int(top.get("regular_price", -1)) == 50000, "top polishing agent regular price must be 50000")
    require(int(top.get("guild_price", -1)) == 48000, "top polishing agent guild price must be 48000")

    market = get_json("/api/market-prices")
    editable_names = {row.get("item_name") for row in market}
    require(MID_POLISH not in editable_names, "fixed shop item leaked into editable market prices")
    require(TOP_POLISH not in editable_names, "fixed shop item leaked into editable market prices")

    invalid_url = BASE_URL + "/api/meister/calculations?fee_rate=" + urllib.parse.quote("0.04")
    try:
        urllib.request.urlopen(invalid_url, timeout=10)
    except urllib.error.HTTPError as exc:
        require(exc.code == 400, "invalid fee must return HTTP 400")
    else:
        raise RuntimeError("unsupported 4% auction fee was accepted")

    categories = get_json("/api/meister/categories")
    require(len(categories) == 5, "Meisterville must expose exactly five categories")

    meta = get_json("/api/meister/meta")
    require(int(meta.get("total_recipe_count", 0)) >= 50, "Meisterville catalog is unexpectedly small")

    calculations = get_json("/api/meister/calculations?category_key=accessory&fee_rate=0.05")
    require(isinstance(calculations, list) and calculations, "accessory calculation results are missing")
    require(any(int(row.get("item_level") or 0) > 0 for row in calculations), "item-level metadata is missing from calculation API")
    for row in calculations[:20]:
        require(int(row.get("input_type_count") or 0) >= 1, "recipe input type count is missing")
        require(float(row.get("input_total_quantity") or 0) > 0, "recipe total material quantity is missing")
        require(int(row.get("output_type_count") or 0) >= 1, "recipe output type count is missing")
        require(float(row.get("output_expected_quantity") or 0) > 0, "recipe expected output quantity is missing")
        require(bool(row.get("source_label")), "recipe source label is missing")

    html = get_text("/")
    require('id="sortMode"' in html, "profit ranking sort control is missing from production HTML")
    require('id="rankLimit"' in html, "Top-N ranking control is missing from production HTML")
    require('id="favoritesOnly"' in html, "favorites-only control is missing from production HTML")
    require('/features.js' in html and '/features.css' in html, "feature assets are missing from production HTML")

    feature_js = get_text("/features.js")
    require("FAVORITES_KEY" in feature_js, "favorites persistence code is missing")
    require("renderCalculationsEnhanced" in feature_js, "enhanced ranking renderer is missing")
    require("row.item_level" in feature_js, "item-level display code is missing")
    feature_css = get_text("/features.css")
    require(".favorite-button" in feature_css, "favorite UI styles are missing")
    require(".recipe-table" in feature_css, "recipe detail table styles are missing")

    print(
        "Maple rules and UI verified: fees=5/3, guild=4, pc-craft-max=10, "
        f"fixed-shop={len(fixed)}, recipes={meta['total_recipe_count']}, "
        f"accessory-details={len(calculations)}, favorites-ui=ok, ranking-ui=ok"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Maple rule verification failed: {exc}", file=sys.stderr)
        raise
