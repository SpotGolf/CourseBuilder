/// The elevation a `CoordinatePath` keeps for `meters`. Paths store elevations to the nearest foot.
func pathElevation(_ meters: Double) -> Double {
    (meters / 0.3048).rounded() * 0.3048
}
