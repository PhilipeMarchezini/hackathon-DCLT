from app import create_app


def test_liveness():
    response = create_app().test_client().get("/health/live")
    assert response.status_code == 200
    assert response.get_json()["service"] == "ngo-service"


def test_create_requires_all_fields():
    response = create_app().test_client().post("/ngos", json={"name": "ONG incompleta"})
    assert response.status_code == 400


def test_create_rejects_non_object_json():
    response = create_app().test_client().post("/ngos", json=[])
    assert response.status_code == 400
