import time
import requests

HOST = "" #Enter the URL to the host
PORT =    #Enter the port number to your host
API_KEY = "" #Enter the API key to your host

BASE_URL = f"{HOST}:{PORT}/sabnzbd/api"
SLEEP_SECONDS = 10
STALL_THRESHOLD = 3  # Number of consecutive slow checks before marking failed

session = requests.Session()

def sab_call(mode, extra_params=None):
    params = {
        "apikey": API_KEY,
        "mode": mode,
        "output": "json",
    }
    if extra_params:
        params.update(extra_params)

    r = session.get(BASE_URL, params=params, timeout=10)
    r.raise_for_status()
    return r.json()

def get_queue():
    return sab_call("queue")

def disconnect_sab():
    return sab_call("disconnect")

def fail_item(nzo_id, name):
    """
    Force a stalled item into SABnzbd history as Failed so Sonarr can detect it.

    Setting priority to 'stop' (-4) tells SABnzbd to halt the download and send
    it immediately to post-processing. Because it's incomplete it will fail there,
    writing a proper Failed history entry that Sonarr's failed download handler
    picks up and triggers a blocklist + redownload.
    """
    resp = sab_call("queue", {
        "name": "priority",
        "value": nzo_id,
        "value2": -4,   # -4 = Stop (send to post-processing now)
    })
    print(f"Set to Stop priority — '{name}' ({nzo_id}) | Response: {resp}")
    return resp

def parse_speed_mbps(queue):
    """Get speed in MB/s from kbpersec field (always a clean float)."""
    try:
        return float(queue.get("kbpersec", 0)) / 1024
    except (ValueError, TypeError):
        return 0.0

stall_item_id = None   # nzo_id of the item we're tracking
stall_count = 0        # how many consecutive slow checks for that item

loop = 1
while True:
    try:
        data = get_queue()
        queue = data.get("queue", {})

        status = (queue.get("status") or "").strip()
        speed_mbps = parse_speed_mbps(queue)
        slots = queue.get("slots", [])

        print(f"Status: {status} | Speed: {speed_mbps:.2f} MB/s")

        if speed_mbps < 1.0 and slots:
            top = slots[0]
            top_id = top.get("nzo_id")
            top_name = top.get("filename", top.get("status", "Unknown"))

            if top_id == stall_item_id:
                stall_count += 1
                print(f"Stall check {stall_count}/{STALL_THRESHOLD} for '{top_name}' ({top_id})")
            else:
                # Different item at the top — reset tracker
                stall_item_id = top_id
                stall_count = 1
                print(f"Tracking new item: '{top_name}' ({top_id}) — check 1/{STALL_THRESHOLD}")

            if stall_count >= STALL_THRESHOLD:
                print(f"Item stalled for {STALL_THRESHOLD} consecutive checks. Forcing to failed history...")
                fail_item(top_id, top_name)
                # Reset so we don't repeatedly fail the same item
                stall_item_id = None
                stall_count = 0
            else:
                resp = disconnect_sab()
                print("Disconnect response:", resp)

        elif speed_mbps >= 1.0:
            # Healthy speed — reset stall tracker
            if stall_item_id is not None:
                print("Speed recovered. Resetting stall tracker.")
            stall_item_id = None
            stall_count = 0

        else:
            # No slots in queue
            stall_item_id = None
            stall_count = 0

    except requests.RequestException as e:
        print("Request failed:", e)

    time.sleep(SLEEP_SECONDS)
    loop += 1
    print(f"Starting loop {loop}")
