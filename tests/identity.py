import uuid


def device(name="Test iPhone", platform="ios"):
    return {"installationID": str(uuid.uuid4()), "name": name, "platform": platform}
