from app import create_app


def test_liveness():
    response = create_app().test_client().get("/health/live")
    assert response.status_code == 200


def test_registration_validates_ngo_id():
    response = create_app().test_client().post(
        "/volunteers", json={"name": "Ana", "email": "ana@example.com", "ngo_id": "x"}
    )
    assert response.status_code == 400


def test_registration_rejects_non_object_json():
    response = create_app().test_client().post("/volunteers", json=[])
    assert response.status_code == 400


def test_registration_requires_positive_ngo_id():
    response = create_app().test_client().post(
        "/volunteers", json={"name": "Ana", "email": "ana@example.com", "ngo_id": -1}
    )
    assert response.status_code == 400
