{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE RecordWildCards #-}

module LSolver.Backend.Cplex(solLP, standardBounds, solMIP, defaultCallBacks, getCallBackLp, getIncCallBackXs, getCallBackXs,
                              addCallBackCut, UserCutCallBack, CutCallBackM, UserIncumbentCallBack, IncumbentCallBackM, CallBacks(..)) where

import Data.Ix as I
import qualified Data.Vector as V
import qualified Data.Sequence as S
import Data.Foldable as F
import CPLEX.Bindings
import CPLEX.Param
import CPLEX.Core hiding (Bound)
--import Foreign.C (CInt)
import LSolver.Bindings
import qualified Data.Vector.Storable as VS
import Foreign.Ptr
import Foreign.ForeignPtr(newForeignPtr_)
import Foreign.Storable
import Foreign.C
import Control.Monad
import Control.Monad.Reader

data CallBacks = ActiveCallBacks {cutcb :: Maybe UserCutCallBack, inccb :: Maybe UserIncumbentCallBack,
                                  lazycb :: Maybe UserCutCallBack}
defaultCallBacks = ActiveCallBacks {cutcb = Nothing, inccb = Nothing, lazycb = Nothing}

type ParamValues = [(CPX_PARAM, Int)]

data CutCallBackArgs = CutCallBackArgs {env :: CpxEnv, cbdata :: Ptr (), wherefrom :: CInt, cbhandle :: Ptr (), userdata :: Ptr Int} 
type CutCallBackM a = (ReaderT CutCallBackArgs IO a) 
type UserCutCallBack = CutCallBackM Int 

data IncumbentCallBackArgs = IncumbentCallBackArgs {envi :: CpxEnv, cbdatai :: Ptr (), wherefromi :: CInt, cbhandlei :: Ptr (),
                                                    objVal :: CDouble, xs :: Ptr CDouble, isfeas :: Ptr Int , useraction :: Ptr Int} 
type IncumbentCallBackM a = (ReaderT IncumbentCallBackArgs IO a) 
type UserIncumbentCallBack = Double -> VS.Vector Double -> IncumbentCallBackM Bool



incumbentcallback :: UserIncumbentCallBack -> CIncumbentCallback
incumbentcallback usercb env' cbdata wherefrom cbhandle objVal xs isfeas useraction = do
    let env = CpxEnv env'
    let oval = realToFrac objVal
    foreignPtr <- newForeignPtr_ xs
    lp <- getCallbackLP env cbdata (fromIntegral wherefrom)
    xs' <- case lp of 
          Right lp' -> do 
                  colCount <- getNumCols env lp'
                  return $ VS.map realToFrac $ VS.unsafeFromForeignPtr0 foreignPtr colCount
          Left _ ->  return VS.empty
    isFeas <- runReaderT (usercb oval xs') $ IncumbentCallBackArgs env cbdata wherefrom cbhandle objVal xs isfeas useraction 
    poke isfeas (if isFeas then 1 else 0) 
    return 0


cutcallback :: UserCutCallBack -> CCutCallback
cutcallback usercb env' cbdata wherefrom cbhandle ptrUser = do
    let env = CpxEnv env'
    runReaderT usercb $ CutCallBackArgs env cbdata wherefrom cbhandle ptrUser

lazycallback :: UserCutCallBack -> CCutCallback
lazycallback usercb env' cbdata wherefrom cbhandle ptrUser = do
    let env = CpxEnv env'
    runReaderT usercb $ CutCallBackArgs env cbdata wherefrom cbhandle ptrUser


getCallBackLp :: CutCallBackM CpxLp
getCallBackLp = do
  CutCallBackArgs{..} <- ask
  res <- liftIO $ getCallbackLP env cbdata (fromIntegral wherefrom)
  case res of
    Right lp -> return lp
    _ -> error "I cant get the LP for some reason"

getIncCallBackXs :: IncumbentCallBackM (V.Vector Double)
getIncCallBackXs = do
    IncumbentCallBackArgs{..} <- ask
  
    lp <- liftIO $ getCallbackLP envi cbdatai (fromIntegral wherefromi)
    xs' <- case lp of 
              Right lp' -> do 
                  colCount <- liftIO $ getNumCols envi lp'
                  (stat, xsVS) <- liftIO $ getCallbackNodeX envi cbdatai (fromIntegral wherefromi) 0 (colCount-1)
                  return $ VS.convert xsVS
              Left msg -> return $ V.empty
    return xs'

getCallBackXs :: CutCallBackM (V.Vector Double)
getCallBackXs = do
    CutCallBackArgs{..} <- ask
  
    lp <- liftIO $ getCallbackLP env cbdata (fromIntegral wherefrom)
    xs' <- case lp of 
              Right lp' -> do 
                  colCount <- liftIO $ getNumCols env lp'
                  (stat, xsVS) <- liftIO $ getCallbackNodeX env cbdata (fromIntegral wherefrom) 0 (colCount-1)
                  return $ VS.convert xsVS
              Left msg -> return $ V.empty
    return xs'

addCallBackCut :: Bound [Variable Int] -> CutCallBackM (Maybe String)
addCallBackCut st = do
    CutCallBackArgs{..} <- ask
    let (cnstrs,rhs) = toForm st
    liftIO $ addCutFromCallback env cbdata wherefrom (fromIntegral $ length cnstrs) rhs cnstrs CPX_USECUT_FORCE
  where
    toForm (vars :< b) = (map (\(v :# i) -> (Col i, v)) vars, L b)  
    toForm (vars :> b) = (map (\(v :# i) -> (Col i, v)) vars, G b)  
    toForm (vars := b) = (map (\(v :# i) -> (Col i, v)) vars, E b) 

standardBounds :: (Enum t, Num a) => (t, t) -> [(t, Maybe a, Maybe a1)]
standardBounds (i,j) = map (\i' -> (i', Just 0, Nothing)) [i..j]

toBounds :: (Num a, Ix t) => [(t, Maybe a, Maybe a1)] -> (t, t) -> [(Maybe a, Maybe a1)]
toBounds bounds varRange = F.toList $ aux bounds def
    where
        def = S.fromList [k | _ <- I.range varRange, let k = (Just 0, Nothing)]
        aux [] s = s
        aux ((b,lb,ub):bs) s = aux bs (S.update (I.index varRange b) (lb,ub) s)

toConstraints :: Ix a => Constraints a -> (a, a) -> ([(Row, Col, Double)], V.Vector Sense)
toConstraints constraints varRange = let (st, rhs) = toStandard constraints 0 [] [] varRange
    in (st, V.fromList rhs)


toStandard :: Ix a => Constraints a -> Int -> [(Row, Col, Double)] -> [Sense] -> (a, a)
                    -> ([(Row, Col, Double)], [Sense])
toStandard (Sparse []) _ accSt accRhs _ = (reverse $ accSt, reverse $ accRhs)
toStandard (Sparse (b:bs)) rowI accSt accRhs varRange = case b of
        vars :< boundVal -> addRow vars L boundVal
        vars := boundVal -> addRow vars E boundVal
        vars :> boundVal -> addRow vars G boundVal
    where   addRow vars s boundVal = toStandard (Sparse bs) (rowI+1) (generateRow vars ++ accSt)
                                                ((s boundVal) : accRhs) varRange
            generateRow [] = []
            generateRow ((v :# i):vs) = (Row rowI, Col $ I.index varRange i, v):generateRow vs


toObj :: Optimization -> (ObjSense, V.Vector Double)
toObj (Maximize dd) = (CPX_MAX, V.fromList dd)
toObj (Minimize dd) = (CPX_MIN, V.fromList dd)


solLP :: LinearProblem Int -> ParamValues -> IO LPSolution
solLP (objective, constraints, bounds, varRange) params = withEnv $ \env -> do
  --setIntParam env CPX_PARAM_SCRIND cpx_ON
  --setIntParam env CPX_PARAM_DATACHECK cpx_ON
  mapM_ (\(p,v) -> setIntParam env p (fromIntegral v)) params
  withLp env "testprob" $ \lp -> do
    let
        (objsen, obj) = toObj objective
        (cnstrs,rhs) = toConstraints constraints varRange
        xbnds = toBounds bounds varRange
   
    statusLp <- copyLp env lp objsen obj rhs cnstrs (V.fromList xbnds)

    case statusLp of
      Nothing -> return ()
      Just msg -> error $ "CPXcopylp error: " ++ msg

    statusOpt <- qpopt env lp
    case statusOpt of
      Nothing -> return ()
      Just msg -> error $ "CPXqpopt error: " ++ msg

    statusSol <- getSolution env lp
    case statusSol of
      Left msg -> error $ "CPXsolution error: " ++ msg
      Right sol -> return $ LPSolution (solStat sol == CPX_STAT_OPTIMAL) (solObj sol) (VS.convert $ solX sol) (VS.convert $ solPi sol)

solMIP :: MixedIntegerProblem Int -> ParamValues -> CallBacks -> IO MIPSolution
solMIP (objective, constraints, bounds, types, varRange) params (ActiveCallBacks {..})  = withEnv $ \env -> do
--  setIntParam env CPX_PARAM_SCRIND 1
 -- setIntParam env CPX_PARAM_DATACHECK 1 
  mapM_ (\(p,v) -> setIntParam env p (fromIntegral v)) params
  withLp env "clu" $ \lp -> do
    let
        (varA, varB) = varRange
        varCount = varB - varA + 1
        (objsen, obj) = toObj objective
        (cnstrs,rhs) = toConstraints constraints varRange
        xbnds = toBounds bounds varRange
        
        types' = V.fromList (replicate varCount CPX_CONTINUOUS) V.// (map (\(a,t) -> (a, typeToCPX t)) types)

    statusLp <- copyMip env lp objsen obj rhs cnstrs (V.fromList xbnds) types' 

    case statusLp of
      Nothing -> return ()
      Just msg -> error $ "CPXcopyMIP error: " ++ msg

    case inccb of 
        Just cb -> do   statusIncCB <- setIncumbentCallback env (incumbentcallback cb)
                        case statusIncCB of
                            Nothing -> return ()
                            Just msg -> error $ "CPXIncumbentCallBackSet Error: " ++ msg
        Nothing -> return ()
    
    case lazycb of 
        Just cb -> do   statusLazyCB <- setLazyConstraintCallback env (lazycallback cb)
                        case statusLazyCB of
                            Nothing -> return ()
                            Just msg -> error $ "CPXLazyConstraintCallBackSet Error: " ++ msg
        Nothing -> return ()

    case cutcb of 
        Just cb -> do   statusCutCB <- setCutCallback env (cutcallback cb)
                        case statusCutCB of
                            Nothing -> return ()
                            Just msg -> error $ "CPXCutCallBackSet Error: " ++ msg
        Nothing -> return ()

    statusOpt <- mipopt env lp
    case statusOpt of
      Nothing -> return ()
      Just msg -> error $ "CPXmipopt error: " ++ msg

    statusSol <- getMIPSolution env lp
    case statusSol of
      Left msg -> error $ "CPXsolution error: " ++ msg
      Right sol -> return $ MIPSolution (solStat sol == CPXMIP_OPTIMAL) (solObj sol) (VS.convert $ solX sol)
       
typeToCPX :: LSolver.Bindings.Type -> CPLEX.Core.Type 
typeToCPX (TInteger) = CPX_INTEGER
typeToCPX (TContinuous) = CPX_CONTINUOUS
typeToCPX (TBinary) = CPX_BINARY
