mapboxgl.accessToken = "pk.eyJ1IjoiZGl6dG9ueTY3IiwiYSI6ImNtbjVjNW1seTA4dWsycXBpbjRreHVoOHQifQ.7wgw3ocLrvjEmpKdx-vP1A";

const map = new mapboxgl.Map({
  container: "map",
  style: "mapbox://styles/mapbox/dark-v11",
  center: [-87.6, 41.8],
  zoom: 10
});

// TEMP SAMPLE DATA (so it works immediately)
const clinicians = [
  { name: "John Doe", role: "PT", lat: 41.88, lng: -87.63 },
  { name: "Jane Smith", role: "PTA", lat: 41.85, lng: -87.68 }
];

const list = document.getElementById("clinicianList");

clinicians.forEach(c => {

  const marker = new mapboxgl.Marker()
    .setLngLat([c.lng, c.lat])
    .setPopup(
      new mapboxgl.Popup().setHTML(`<b>${c.name}</b><br>${c.role}`)
    )
    .addTo(map);

  const div = document.createElement("div");
  div.className = "card";
  div.innerHTML = `${c.name} - ${c.role}`;

  div.onclick = () => {
    map.flyTo({
      center: [c.lng, c.lat],
      zoom: 13
    });
  };

  list.appendChild(div);
});