--
-- Paced Serial Task
--
-- This is intended as an abstract, pure module that handles all the task score and time keeping.
--
module Psat where

import Time
import String
import Random
import Debug exposing (log, watch)


--
-- HELPERS
--
-- (This is stuff that should really stay in a libray... -_-
--
randomChoice : List a -> Random.Seed -> (Maybe a, Random.Seed)
randomChoice list seed =
    let
        generator = Random.int 0 (List.length list - 1)
        (index, seed') = Random.generate generator seed
        choice = List.head <| List.drop index list
    in
        (choice, seed')


takeWhile : (a -> Bool) -> List a -> List a
takeWhile predicate list =
    case list of
        x :: xs -> if predicate x then x :: takeWhile predicate xs else []
        [] -> []


--
-- Model
--
type Action pq answer
    = AnswerTimeout SessionId
    | UserAnswers answer
    | Start
    | ManualStop
    | AutomaticStop SessionId
    | UpdateIsi String
    | UpdateDuration String


type Outcome
    = Right
    | Wrong
    | Missed


type alias Isi = Int
type alias Duration = Int
type alias SessionId = Int
type alias Key pq answer = (List pq -> Maybe answer)

type alias Model pq answer =
    { key : Key pq answer
    , pqs : List pq
    , userHasAnswered : Bool
    , isRunning : Bool
    , addedPqs : List pq
    , isi : Isi

    , sessionId : SessionId
    , duration : Duration
    , seed : Random.Seed

    , log : List (Time.Time, Action pq answer)
    , outcomes : List Outcome
    }

-- TODO: initialise seed with timer
model : Key pq answer -> List pq -> Isi -> Duration -> Model pq answer
model key pqs isi duration =
    Model key pqs True False [] isi 0 duration (Random.initialSeed 0) [] []


--
-- Triggers
--
-- They are kind of Effects, but they offload the actual dirty work to the caller
--
type Trigger pq answer
    = TriggerDelayedAction Time.Time (Action pq answer)
    | TriggerSound (Maybe pq)


getNewPqTriggers : Model pq answer -> List (Trigger pq answer)
getNewPqTriggers model =
    [ TriggerDelayedAction (toFloat model.isi * Time.millisecond) (AnswerTimeout model.sessionId)
    , TriggerSound (List.head model.addedPqs)
    ]


getTriggers : Model pq answer -> Action pq answer -> List (Trigger pq answer)
getTriggers model action =
    case action of
        Start ->
            TriggerDelayedAction (toFloat model.duration * Time.minute) (AutomaticStop model.sessionId)
            :: getNewPqTriggers model

        AnswerTimeout sessionId ->
            if sessionId /= model.sessionId || not model.isRunning
            then []
            else getNewPqTriggers model

        _ ->
            []


--
-- Model update
--

-- isi must increase if there are 4 failures in a row, and decrease if there are 4 success in a row.
outcomeDelta : (Outcome -> Bool) -> List Outcome -> Int
outcomeDelta predicate outcomes =
   let
       count = List.length <| takeWhile predicate outcomes
   in
      if count > 0 && rem count 4 == 0 then 1 else 0


isiDirection : List Outcome -> Int
isiDirection outcomes =
    outcomeDelta ((/=) Right) outcomes - outcomeDelta ((==) Right) outcomes


setIsi : Model a b -> Model a b
setIsi model =
    { model | isi = isiDirection model.outcomes * 100 + model.isi }


setOutcome : Model pq answer -> Outcome -> Model pq answer
setOutcome model outcome =
    if model.userHasAnswered
    then model
    else
        { model
        | userHasAnswered = True
        , outcomes = outcome :: model.outcomes
        } |> setIsi


setAnswer : Model pq answer -> Maybe answer -> Model pq answer
setAnswer model maybeAnswer =
    case model.key model.addedPqs of
        Nothing ->
            model

        Just correctAnswer ->
            case maybeAnswer of
                Nothing ->
                    setOutcome model Missed

                Just answer ->
                    setOutcome model <| if answer == correctAnswer then Right else Wrong


addRandomPq : Model pq answer -> Model pq answer
addRandomPq model =
    let
        (pq, seed) = randomChoice model.pqs model.seed
    in
       case pq of
           Nothing -> Debug.crash "Zero partial qustions specified!"
           Just pq' ->
               { model
               | addedPqs = pq' :: model.addedPqs
               , userHasAnswered = False
               , seed = seed
               }


updateWhenRunning : Action pq answer -> Model pq answer -> Model pq answer
updateWhenRunning action model =
    case action of
        ManualStop ->
            { model | isRunning = False }

        AutomaticStop sessionId ->
            if sessionId /= model.sessionId then model else { model | isRunning = False }

        UserAnswers answerValue ->
            setAnswer model <| Just answerValue

        AnswerTimeout sessionId ->
            if sessionId /= model.sessionId then model else (setAnswer model Nothing |> addRandomPq)

        _ ->
            model


updateWhenNotRunning : Action pq answer -> Model pq answer -> Model pq answer
updateWhenNotRunning action model =
    case action of
        Start ->
            { model
            | isRunning = True
            , sessionId = model.sessionId + 1
            , addedPqs = []
            , outcomes = []
            } |> addRandomPq

        UpdateIsi isiString ->
            case String.toInt isiString of
                Ok isi ->
                    { model | isi = isi }

                Err _ ->
                    model

        UpdateDuration durationString ->
            case String.toInt durationString of
                Ok duration ->
                    { model | duration = duration }

                Err _ ->
                    model

        _ ->
            model


--
-- Main update
--
update : (Time.Time, Action pq answer) -> Model pq answer -> (Model pq answer, List (Trigger pq answer))
update (actionTimestamp, action) model =
    let
        updateModel =
            if model.isRunning then updateWhenRunning else updateWhenNotRunning

        updatedModel =
            (updateModel action { model | log = (actionTimestamp, action) :: model.log })
    in
       (updatedModel, getTriggers updatedModel action)
