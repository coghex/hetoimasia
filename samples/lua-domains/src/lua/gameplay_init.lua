-- The gameplay VM's initial chunk. It runs before any module.
--
-- The standard `math` library is opened whole, so `math.random` and `math.randomseed` are removed
-- here: gameplay's only source of randomness is the application-owned stream behind `rand.below`
-- (D-23, D-44), and nothing a script does can reseed or bypass it. The UI VM keeps `math.random`.
math.random = nil
math.randomseed = nil
