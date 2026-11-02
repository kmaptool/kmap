extension BuildPipeline {
    /// Shares of a build's time, from measured builds. The split, the contours and the
    /// compile share 0.53 as rebuilds from the cache time them; the network's stages keep
    /// 0.44. Contours are traced while the split runs, so they add little of their own.
    /// Each row's weights are the ones its bar strays least with; the table's are those
    /// of all rows together.
    ///
    ///     seconds, opentopomap, 20 m contours, DEM, index
    ///
    ///                                                 split       contours    compile     weights fit
    ///     OS                  region
    ///     M4 Pro, macOS       region 1                1.8         0.8         13.0        0.085 / 0.03 / 0.415
    ///                         region 2                10.2        2.6         62.0        0.12 / 0.005 / 0.405
    ///                         region 3                9.5         3.4         55.4        0.11 / 0.005 / 0.415
    ///                         region 4                18.6        3.4         91.7        0.145 / 0.005 / 0.38
    ///                         region 5                35.1        8.6         194.5       0.085 / 0.005 / 0.44
    ///
    ///     Windows 11 VM       region 1                2.9         1.0         52.6        0.03 / 0.015 / 0.485
    ///                         region 2                29.2        11.8        140.7       0.13 / 0.03 / 0.37
    ///                         region 3                27.9        8.1         186.2       0.13 / 0.005 / 0.395
    ///                         region 4                53.0        10.9        212.2       0.175 / 0.005 / 0.35
    ///                         region 5                103.6       26.7        473.7       0.13 / 0.005 / 0.395
    ///
    ///     Linux, Docker       region 1                8.1         6.1         25.9        0.17 / 0.03 / 0.33
    ///                         region 2                41.4        23.6        190.2       0.10 / 0.005 / 0.425
    ///                         region 3                51.4        35.5        153.9       0.12 / 0.03 / 0.38
    ///                         region 4                80.0        22.2        242.5       0.14 / 0.005 / 0.385
    ///
    ///     all rows                                                                        0.13 / 0.005 / 0.395
    struct StageWeights {
        let shares: [StageID: Double]

        static let measured = StageWeights(shares: [
            .preflight: 0.01, .dataUpdate: 0.01, .download: 0.23, .elevation: 0.20,
            .elevationBuild: 0.005, .split: 0.13, .compile: 0.395, .collect: 0.02
        ])

        subscript(stage: StageID) -> Double { shares[stage] ?? 0 }
    }
}
