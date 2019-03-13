{-# LANGUAGE RecordWildCards #-}
-- Copyright   : (c) 2019 Robert Künnemann
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Robert Künnemann <robert@kunnemann.de>
-- Portability : GHC only
--
-- TODO
module Sapic.Facts (
     TransAction(..)
   , TransFact(..)
   , AnnotatedRule(..)
   , StateKind(..)
   , isSemiState
   , factToFact
   , actionToFact
   , toRule
) where
-- import Data.Maybe
-- import Data.Foldable
-- import Control.Exception
-- import Control.Monad.Fresh
-- import Control.Monad.Catch
-- import Sapic.Exceptions
import Theory
import Theory.Text.Parser
import Theory.Sapic
import Theory.Sapic.Print
import Sapic.Annotation
-- import Theory.Model.Rule
-- import Theory.Model.Rule
-- import Data.Typeable
-- import Data.Text
import Data.Char
import qualified Data.Set as S
import Data.Color
-- import Control.Monad.Trans.FastFresh

data TransAction =  InitEmpty
  | InitId
  | StopId
  | EventEmpty
  | EventId
  | Predicate LNFact
  | NegPredicate LNFact
  | ProgressFrom ProcessPosition 
  | ProgressTo ProcessPosition ProcessPosition
  | Listen ProcessPosition LVar 
  | Receive ProcessPosition SapicTerm
  | IsIn SapicTerm LVar
  | IsNotSet SapicTerm
  | InsertA SapicTerm SapicTerm
  | DeleteA SapicTerm 
  | ChannelIn SapicTerm
  | Send ProcessPosition SapicTerm
  | LockUnnamed SapicTerm LVar
  | LockNamed SapicTerm LVar
  | UnlockUnnamed SapicTerm LVar
  | UnlockNamed SapicTerm LVar
  | TamarinAct LNFact

data StateKind  = LState | PState | LSemiState | PSemiState

data TransFact =  Fr LVar | In SapicTerm 
            | Out SapicTerm
            | Message SapicTerm SapicTerm
            | Ack SapicTerm SapicTerm
            | State StateKind ProcessPosition (S.Set LVar)
            | MessageIDSender ProcessPosition
            | MessageIDReceiver ProcessPosition
            | TamarinFact LNFact

data AnnotatedRule ann = AnnotatedRule { 
      processName  :: Maybe String
    , process      :: AnProcess ann
    , position     :: ProcessPosition
    , prems        :: [TransFact]
    , acts         :: [TransAction]  
    , concs        :: [TransFact]
    , index        :: Int
}

-- data Fact t = Fact
--     { factTag         :: FactTag
--     , factAnnotations :: S.Set FactAnnotation
--     , factTerms       :: [t]
--     }
-- -- | A protocol fact denotes a fact generated by a protocol rule.
-- protoFact :: Multiplicity -> String -> [t] -> Fact t
-- protoFact multi name ts = Fact (ProtoFact multi name (length ts)) S.empty ts

isSemiState :: StateKind -> Bool
isSemiState LState = False
isSemiState PState = False
isSemiState LSemiState = True
isSemiState PSemiState = True

multiplicity :: StateKind -> Multiplicity
multiplicity LState = Linear
multiplicity LSemiState = Linear
multiplicity PState = Persistent
multiplicity PSemiState = Persistent

mapFactName f fact =  fact { factTag = f' (factTag fact) } 
    where f' (ProtoFact m s i) = ProtoFact m (f s) i
          f' ft = ft


-- Optimisation: have a diffeent Fact name for every (unique) locking variable 
lockFactName v = "Lock_"++ (show $ lvarIdx v)
unlockFactName v = "Unlock_"++ (show $ lvarIdx v)
lockPubTerm = pubTerm . show . lvarIdx
-- actionToFact :: TransAction -> Fact t
actionToFact InitEmpty = protoFact Linear "Init" []
  -- | StopId
  -- | EventEmpty
  -- | EventId
  -- | ProgressFrom ProcessPosition 
  -- | ProgressTo ProcessPosition ProcessPosition
  -- | Listen ProcessPosition LVar 
  -- | Receive ProcessPosition SapicTerm
actionToFact (IsIn t v)   =  protoFact Linear "IsIn" [t,varTerm v]
actionToFact (IsNotSet t )   =  protoFact Linear "IsNotSet" [t]
actionToFact (InsertA t1 t2)   =  protoFact Linear "Insert" [t1,t2]
actionToFact (DeleteA t )   =  protoFact Linear "Delete" [t]
actionToFact (ChannelIn t)   =  protoFact Linear "ChannelIn" [t]
actionToFact (Predicate f)   =  mapFactName (\s -> "Pred_" ++ s) f
actionToFact (NegPredicate f)   =  mapFactName (\s -> "Pred_Not_" ++ s) f
actionToFact (LockNamed t v)   = protoFact Linear (lockFactName v) [lockPubTerm v,t, varTerm v ]
actionToFact (LockUnnamed t v)   = protoFact Linear "Lock" [lockPubTerm v, t, varTerm v ]
actionToFact (UnlockNamed t v) = protoFact Linear (unlockFactName v) [lockPubTerm v,t, varTerm v]
actionToFact (UnlockUnnamed t v) = protoFact Linear "Unlock" [lockPubTerm v,t,varTerm v]
actionToFact (TamarinAct f) = f

-- | Term with variable for message id. Uniqueness ensured by process position.
varTermMID :: ProcessPosition -> VTerm c LVar
varTermMID p = varTerm $ LVar n s i
    where n = "mid_" ++ prettyPosition p
          s = LSortFresh
          i = 0 -- This is the message indexx. We could compute it from the position, but not sure if this makes things simpler.

factToFact :: TransFact -> Fact SapicTerm
factToFact (Fr v) = freshFact $ varTerm (v)
factToFact (In t) = inFact t
factToFact (Out t) = outFact t
factToFact (Message t t') = protoFact Linear "Message" [t, t']
factToFact (Ack t t') = protoFact Linear "Ack" [t, t']
factToFact (MessageIDSender p) = protoFact Linear "MID_Sender" [ varTermMID p ]
factToFact (MessageIDReceiver p) = protoFact Linear "MID_Receiver" [ varTermMID p ]
factToFact (State kind p vars) = protoFact (multiplicity kind) (name kind ++ "_" ++ prettyPosition p) ts
    where
        name k = if isSemiState k then "semistate" else "state"
        ts = map varTerm (S.toList vars)
factToFact (TamarinFact f) = f

toRule :: AnnotatedRule ann -> Rule ProtoRuleEInfo
toRule AnnotatedRule{..} = -- this is a Record Wildcard
          Rule (ProtoRuleEInfo (StandRule name) attr) l r a (newVariables l r)
          where
            name = case processName of 
                Just s -> s
                Nothing -> stripNonAlphanumerical (prettySapicTopLevel process) ++ "_" ++ show index ++ "_" ++ prettyPosition position
            attr = [RuleColor $ RGB 0.3 0.3 0.3, Process $ toProcess process] -- TODO compute color from
            l = map factToFact prems
            a = map actionToFact acts
            r = map factToFact concs

stripNonAlphanumerical :: String -> String
stripNonAlphanumerical = filter (\x -> isAlpha x)
