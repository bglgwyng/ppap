module Z.System.Path where

import qualified System.Path as Path
import qualified System.Path.Directory as Directory
import qualified System.Path.Windows as Windows

matchFileDirWithExtension :: String -> (String, String)
matchFileDirWithExtension dir
    = case span (\ch -> ch /= '.') (reverse dir) of
        (reversed_extension, '.' : reversed_filename) -> (reverse reversed_filename, '.' : reverse reversed_extension)
        (reversed_filename, must_be_null) -> (reverse reversed_filename, [])

toWindowsAbsPath :: String -> IO (Maybe String)
toWindowsAbsPath = maybe (return Nothing) (fmap toString . Directory.canonicalizePath) . fromString where
    toString :: Windows.AbsDir -> Maybe String
    toString = uncurry go . span (\ch -> ch /= ':') . Windows.toString where
        go :: String -> String -> Maybe String
        go drive path
            | take 3 path == drivesuffix = return (drive ++ path)
            | take 2 path == take 2 drivesuffix = return (drive ++ drivesuffix ++ drop 2 path)
            | otherwise = Nothing
        drivesuffix :: String
        drivesuffix = ":\\\\"
    fromString :: String -> Maybe Windows.RelDir
    fromString = Windows.maybe

makePathAbsolutely :: String -> IO (Maybe String)
makePathAbsolutely = toWindowsAbsPath