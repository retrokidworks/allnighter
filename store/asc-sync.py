"""
App Store Connect 를 저장소 값과 같게 맞추고, submit 단계에서 심사에 낸다(멱등 — 몇 번 돌려도 같은 결과).
  cd personal/allnighter/store && uvx --from pyjwt --with cryptography python asc-sync.py [단계...]
단계: version app-info localizations screenshots age-rating pricing review build submit resubmit (생략하면 submit·resubmit 빼고 전부)
거절된 뒤에는 고친 단계만 돌리고 resubmit(같은 제출 건을 다시 낸다).
스크린샷은 render.sh 가 만든 01.jpg·02.jpg. App Store 판 기능만 적는다(뚜껑 닫기는 직접 배포판 전용, 어둡게는 밝기 키 방식).
eggtimer 의 store/asc/sync.py 와 같은 틀이다. API 키는 저장소 밖 ~/.appstoreconnect/private_keys 에 있다.
"""
import hashlib, json, os, sys, time, urllib.error, urllib.request
import jwt

APP_ID = "6816585258"
VERSION = "0.1.3"  # tools/app-store.sh 에 준 버전과 같아야 빌드를 붙일 수 있다
BUILD_NUMBER = "2609271331"
SITE_URL = "https://allnighter.retrokidworks.com"
PRIVACY_URL = SITE_URL + "/privacy.html"
COPYRIGHT = "2026 retrokidworks"
# 심사 연락처는 이미 심사에 낸 앱(CryptoTracker Menubar)의 것을 그대로 쓴다.
REVIEW_CONTACT_FROM_APP = "6814690874"
KEY_ID, ISSUER = "2TB4M76BXX", "69a6de8b-dd84-47e3-e053-5b8c7c11a4d1"
KEY = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")).read()
HERE = os.path.dirname(os.path.abspath(__file__))
SCREENSHOT_TYPE = "APP_DESKTOP"  # 2880×1800

# 다른 앱 이름(Amphetamine·Caffeine 등)은 키워드에 넣지 않는다 — 2.3.7 로 거절된다.
# 부제에 "Mac" 을 넣지 않는다 — 5.2.5(Apple 상표)로 거절된다.
LISTING = {
    "name": "Allnighter – Keep Awake",
    "subtitle": "Stay awake, dim the display",
    "keywords": "awake,no sleep,prevent sleep,stay awake,insomnia,menu bar,idle,display,screen,timer,battery",
    "promotionalText": "Right-click the eye in the menu bar to start. Right-click again to stop.",
    "description": """Allnighter keeps your Mac awake, so downloads, builds, renders, uploads and long calls keep going while you step away — and it can turn the screen down to black while it works.

Pick how long to wait under Dim display after. When you haven't touched the mouse or keyboard for that long, Allnighter lowers the display brightness all the way. Move the mouse and it comes back to the brightness you chose.

Right-click the eye in the menu bar to start. Right-click again to stop. Or pick a time — 15 or 30 minutes, or 1, 2, 4 or 8 hours — and Allnighter stops on its own.

• Lives in the menu bar, no Dock icon
• Dims the display when you're away, brings it back when you return
• Right-click to start or stop in one move
• Timed sessions from 15 minutes to 8 hours
• A short sound when a session starts and ends, which you can turn off
• Launch at login
• No account, no tracking, no network access

Dimming works by pressing the brightness keys for you, so macOS asks you once to allow Allnighter in System Settings › Privacy & Security.

Allnighter is free and open source.""",
}


class ApiError(Exception):
    pass


def call(method, path, body=None):
    token = jwt.encode(
        {"iss": ISSUER, "iat": int(time.time()), "exp": int(time.time()) + 1100, "aud": "appstoreconnect-v1"},
        KEY, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as res:
            raw = res.read()
            return json.loads(raw) if raw else None  # 관계 PATCH 는 204 빈 본문이다
    except urllib.error.HTTPError as e:
        raise ApiError(f"{method} {path} → {e.code} {e.read().decode()[:600]}") from None


def rel(kind, id_):
    return {"data": {"type": kind, "id": id_}}


# 고칠 수 있는 버전 상태. 심사 제출을 거둬들이면(reviewSubmissions canceled) DEVELOPER_REJECTED, 심사에서 거절되면 REJECTED 가 된다.
EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED")


def app_info():
    infos = [i for i in call("GET", f"/v1/apps/{APP_ID}/appInfos")["data"]
             if i["attributes"]["appStoreState"] in EDITABLE_STATES]
    if len(infos) != 1:
        raise SystemExit("고칠 수 있는 appInfo 가 하나가 아니다")
    return infos[0]



# 깨어 있기 유틸리티라 해당 항목이 없다. 값은 같은 "해당 없음"으로 심사를 통과한 CryptoTracker 의 선언과 같다.
AGE_RATING_NONE = {
    "advertising": False, "ageAssurance": False, "gambling": False, "healthOrWellnessTopics": False,
    "lootBox": False, "messagingAndChat": False, "parentalControls": False, "socialMedia": False,
    "unrestrictedWebAccess": False, "userGeneratedContent": False,
    "alcoholTobaccoOrDrugUseOrReferences": "NONE", "contests": "NONE", "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE", "horrorOrFearThemes": "NONE", "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE", "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE", "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE", "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
}


def step_age_rating():
    info = app_info()
    decl = call("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    call("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}", {"data": {
        "type": "ageRatingDeclarations", "id": decl["id"], "attributes": AGE_RATING_NONE}})
    print("age rating: none")


def step_pricing():
    # 무료 가격과 전 지역 판매. 이미 있으면 409 가 나는데, 같은 설정이 들어가 있다는 뜻이다.
    points = call("GET", f"/v1/apps/{APP_ID}/appPricePoints?filter[territory]=USA&limit=200")["data"]
    free = next(p for p in points if p["attributes"]["customerPrice"] in ("0", "0.0", "0.00"))
    try:
        call("POST", "/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
            "app": rel("apps", APP_ID), "baseTerritory": rel("territories", "USA"),
            "manualPrices": {"data": [{"type": "appPrices", "id": "${price}"}]}}},
            "included": [{"type": "appPrices", "id": "${price}", "attributes": {"startDate": None},
                          "relationships": {"appPricePoint": rel("appPricePoints", free["id"])}}]})
    except ApiError as e:
        if "409" not in str(e):
            raise
    territories = []
    url = "/v1/territories?limit=200"
    while url:
        page = call("GET", url)
        territories += [t["id"] for t in page["data"]]
        url = page["links"].get("next")
    try:
        call("POST", "/v2/appAvailabilities", {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"app": rel("apps", APP_ID), "territoryAvailabilities": {
                "data": [{"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in territories]}}},
            "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                          "relationships": {"territory": rel("territories", t)}} for t in territories]})
    except ApiError as e:
        if "409" not in str(e):
            raise
    print("free,", len(territories), "territories")



def app_store_version():
    data = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=MAC_OS")["data"]
    editable = [v for v in data if v["attributes"]["appStoreState"] in EDITABLE_STATES]
    if len(editable) != 1:
        raise SystemExit(f"고칠 수 있는 버전이 하나가 아니다: {[v['attributes'] for v in data]}")
    return editable[0]


def step_version():
    v = app_store_version()
    call("PATCH", f"/v1/appStoreVersions/{v['id']}", {"data": {"type": "appStoreVersions", "id": v["id"], "attributes": {
        "versionString": VERSION, "copyright": COPYRIGHT, "releaseType": "AFTER_APPROVAL"}}})
    print("version", VERSION)


def step_app_info():
    info = app_info()
    call("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": rel("appCategories", "UTILITIES"),
        "secondaryCategory": rel("appCategories", "PRODUCTIVITY")}}})
    call("PATCH", f"/v1/apps/{APP_ID}", {"data": {"type": "apps", "id": APP_ID, "attributes": {
        "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
    print("categories UTILITIES / PRODUCTIVITY, content rights")


def upsert_localization(kind, parent_path, parent_rel, attributes):
    existing = {l["attributes"]["locale"]: l for l in call("GET", f"{parent_path}?limit=200")["data"]}
    if "en-US" in existing:
        l = existing["en-US"]
        call("PATCH", f"/v1/{kind}/{l['id']}", {"data": {"type": kind, "id": l["id"], "attributes": attributes}})
    else:
        call("POST", f"/v1/{kind}", {"data": {"type": kind, "attributes": {"locale": "en-US", **attributes},
                                              "relationships": parent_rel}})


def step_localizations():
    info, v = app_info(), app_store_version()
    upsert_localization("appInfoLocalizations", f"/v1/appInfos/{info['id']}/appInfoLocalizations",
                        {"appInfo": rel("appInfos", info["id"])},
                        {"name": LISTING["name"], "subtitle": LISTING["subtitle"], "privacyPolicyUrl": PRIVACY_URL})
    upsert_localization("appStoreVersionLocalizations", f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations",
                        {"appStoreVersion": rel("appStoreVersions", v["id"])},
                        {"description": LISTING["description"], "keywords": LISTING["keywords"],
                         "promotionalText": LISTING["promotionalText"], "supportUrl": SITE_URL, "marketingUrl": SITE_URL})
    print("localizations en-US")


def step_screenshots():
    v = app_store_version()
    loc_id = next(l["id"] for l in call("GET", f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
                  if l["attributes"]["locale"] == "en-US")
    sets = call("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
    target = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == SCREENSHOT_TYPE), None)
    if target is None:
        target = call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {
            "screenshotDisplayType": SCREENSHOT_TYPE}, "relationships": {
            "appStoreVersionLocalization": rel("appStoreVersionLocalizations", loc_id)}}})["data"]
    # 다시 올리면 기존 것을 지우고 순서대로 새로 올린다(멱등).
    for shot in call("GET", f"/v1/appScreenshotSets/{target['id']}/appScreenshots")["data"]:
        call("DELETE", f"/v1/appScreenshots/{shot['id']}")
    for name in ("01.jpg", "02.jpg"):
        blob = open(os.path.join(HERE, name), "rb").read()
        shot = call("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {
            "fileName": name, "fileSize": len(blob)}, "relationships": {
            "appScreenshotSet": rel("appScreenshotSets", target["id"])}}})["data"]
        for op in shot["attributes"]["uploadOperations"]:
            chunk = blob[op["offset"]:op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], method=op["method"], data=chunk,
                                         headers={h["name"]: h["value"] for h in op["requestHeaders"]})
            urllib.request.urlopen(req).read()
        call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
    print("screenshots 2")


def step_review():
    source = call("GET", f"/v1/apps/{REVIEW_CONTACT_FROM_APP}/appStoreVersions?include=appStoreReviewDetail")
    detail = next(i for i in source.get("included", []) if i["type"] == "appStoreReviewDetails")["attributes"]
    contact = {k: detail[k] for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")}
    attrs = {**contact, "demoAccountRequired": False,
             "notes": "Menu bar app with no Dock icon or window. Click the eye icon in the menu bar to open the menu and choose "
                      "Start, or right-click the icon to start and stop. While a session is on, the Mac does not go to idle sleep "
                      "(visible in Terminal with `pmset -g assertions`).\n\n"
                      "Dim display after (optional): the app posts the system brightness-down / brightness-up key events "
                      "(CGEvent, PostEvent permission) and nothing else. This is the only way to lower the display brightness "
                      "from a sandboxed app. To test: choose Dim display after › 1 minute, allow Allnighter when System Settings "
                      "opens, choose Reopen Allnighter to finish setup in the menu, then Start and leave the Mac untouched for one "
                      "minute. The screen goes dark; move the mouse and brightness returns to the level chosen under "
                      "Brightness when you're back. No account or network access is needed."}
    v = app_store_version()
    try:
        existing = call("GET", f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail")["data"]
    except ApiError:
        existing = None
    if existing:
        call("PATCH", f"/v1/appStoreReviewDetails/{existing['id']}", {"data": {"type": "appStoreReviewDetails", "id": existing["id"], "attributes": attrs}})
    else:
        call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
            "relationships": {"appStoreVersion": rel("appStoreVersions", v["id"])}}})
    print("review contact", contact["contactEmail"])


def step_build():
    builds = call("GET", f"/v1/builds?filter[app]={APP_ID}&filter[version]={BUILD_NUMBER}")["data"]
    if len(builds) != 1 or builds[0]["attributes"]["processingState"] != "VALID":
        raise SystemExit(f"빌드 {BUILD_NUMBER} 이 VALID 로 하나가 아니다")
    v = app_store_version()
    call("PATCH", f"/v1/appStoreVersions/{v['id']}/relationships/build", rel("builds", builds[0]["id"]))
    print("build", BUILD_NUMBER, "attached")


def step_submit():
    v = app_store_version()
    submission = call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {
        "platform": "MAC_OS"}, "relationships": {"app": rel("apps", APP_ID)}}})["data"]
    call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
        "reviewSubmission": rel("reviewSubmissions", submission["id"]),
        "appStoreVersion": rel("appStoreVersions", v["id"])}}})
    call("PATCH", f"/v1/reviewSubmissions/{submission['id']}", {"data": {"type": "reviewSubmissions",
        "id": submission["id"], "attributes": {"submitted": True}}})
    print("submitted for review", submission["id"])


def step_resubmit():
    # 거절된 제출 건(UNRESOLVED_ISSUES)의 항목을 resolved 로 바꾼 뒤 다시 낸다. resolved 를 빼면 409 "Version is not ready".
    subs = call("GET", f"/v1/reviewSubmissions?filter[app]={APP_ID}&filter[state]=UNRESOLVED_ISSUES&include=items")
    if len(subs["data"]) != 1:
        raise SystemExit("거절된 제출 건이 하나가 아니다")
    submission = subs["data"][0]
    for item in subs["included"]:
        call("PATCH", f"/v1/reviewSubmissionItems/{item['id']}", {"data": {"type": "reviewSubmissionItems",
            "id": item["id"], "attributes": {"resolved": True}}})
    call("PATCH", f"/v1/reviewSubmissions/{submission['id']}", {"data": {"type": "reviewSubmissions",
        "id": submission["id"], "attributes": {"submitted": True}}})
    print("resubmitted for review", submission["id"])


STEPS = {"version": step_version, "app-info": step_app_info, "localizations": step_localizations,
         "screenshots": step_screenshots, "age-rating": step_age_rating, "pricing": step_pricing,
         "review": step_review, "build": step_build, "submit": step_submit, "resubmit": step_resubmit}
for name in sys.argv[1:] or [s for s in STEPS if s not in ("submit", "resubmit")]:
    STEPS[name]()
